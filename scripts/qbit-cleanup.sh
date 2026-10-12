#!/usr/bin/env bash
# qbit-cleanup.sh - seeding garbage collector for the owner's ACTUAL intent:
#
#   "Seed forever while the content is in my library; when the library copy
#    is gone, the torrent (and its bytes) should go too."
#
# The oracle for "in my library" is the HARDLINK itself: *arr imports are
# hardlinks, so a torrent payload file with st_nlink >= 2 IS the library
# file (same inode). No *arr API guesswork needed for the KEEP decision.
#
# Decision tree per torrent (managed = has a category, i.e. came from an
# *arr; uncategorized/manual torrents are NEVER touched):
#
#   state == missingFiles                      -> remove entry (payload is
#                                                 already gone: this is
#                                                 *arr upgrade residue -
#                                                 Sonarr/Radarr deleted the
#                                                 library file, leaving the
#                                                 torrent errored forever)
#   payload fully hardlinked (all nlink >= 2)  -> KEEP (seeding for library;
#                                                 exactly what owner wants)
#   payload partially hardlinked               -> report only (season pack
#                                                 where some episodes were
#                                                 upgraded; deleting would
#                                                 stop seeding good files)
#   payload not linked (not in library):
#     in *arr queue as importBlocked/Pending   -> never-imported backlog
#                                                 (quality/custom-format
#                                                 rejected; *arr will never
#                                                 import it) -> remove+files
#                                                 after GRACE_DAYS
#     NOT in any *arr queue                    -> imported once, library copy
#                                                 since deleted (owner's
#                                                 remove-from-library flow)
#                                                 -> remove+files after
#                                                 GRACE_DAYS
#
# Native *arr cannot do this: "Remove Completed" only fires on seeding
# goals, and rejected imports sit in the queue forever - there is no
# built-in "delete downloads I refused to import" (that backlog was
# ~130 items / ~47 GB + the 42 errored entries at 2026-10-12).
#
# Usage:
#   ./scripts/qbit-cleanup.sh              # DRY RUN (default): full report
#   ./scripts/qbit-cleanup.sh --delete     # execute removals
#   GRACE_DAYS=30 ./scripts/qbit-cleanup.sh
#
# qBittorrent API reports POD paths (/srv/misc/torrents/... fastresume
# compat mount); translated to host paths for inode checks.
set -euo pipefail
cd "$(dirname "$0")/.."
. secrets/qbittorrent.env
. secrets/arr.env
DELETE=0; [ "${1:-}" = "--delete" ] && DELETE=1
GRACE_DAYS="${GRACE_DAYS:-14}"
BASE="http://${QBIT_HOST:-nas}:8080"

LINE=$(curl -s -c - -H "Referer: $BASE/" \
  --data-urlencode "username=${QBIT_WEBUI_USER}" \
  --data-urlencode "password=${QBIT_WEBUI_PASS}" \
  "$BASE/api/v2/auth/login" | grep -E 'QBT_SID' | tail -1)
COOKIE_NAME=$(echo "$LINE" | awk '{print $6}')
COOKIE_VALUE=$(echo "$LINE" | awk '{print $7}')
[ -n "${COOKIE_VALUE:-}" ] || { echo "login failed" >&2; exit 1; }
COOKIE="Cookie: ${COOKIE_NAME}=${COOKIE_VALUE};"

curl -s -H "Referer: $BASE/" -H "$COOKIE" "$BASE/api/v2/torrents/info" > /tmp/opencode/qbit-cleanup-torrents.json

# *arr queues (ClusterIP only - fetch from inside the pods). downloadId ==
# the qBittorrent torrent hash. Loop pages: queues exceed one page (888
# records at 2026-10-12).
for app in radarr sonarr; do
  key=$([ $app = radarr ] && echo "$RADARR_APIKEY" || echo "$SONARR_APIKEY")
  port=$([ $app = radarr ] && echo 7878 || echo 8989)
  : > /tmp/opencode/qbit-cleanup-$app.json
  page=1
  while : ; do
    kubectl -n media exec deploy/$app -- sh -c \
      "wget -qO- --header='X-Api-Key: $key' 'http://localhost:$port/api/v3/queue?page=$page&pageSize=500'" \
      > /tmp/opencode/qbit-cleanup-$app-page.json
    if python3 - "$app" "$page" <<'PYEOF'
import json, sys
app, page = sys.argv[1], sys.argv[2]
q = json.load(open(f"/tmp/opencode/qbit-cleanup-{app}-page.json"))
with open(f"/tmp/opencode/qbit-cleanup-{app}.json", "a") as f:
    for r in q["records"]: f.write(json.dumps(r) + "\n")
print(f"{app} page {page}: {len(q['records'])} records (total {q.get('totalRecords')})")
sys.exit(0 if len(q["records"]) == 500 else 1)
PYEOF
    then page=$((page + 1)); else break; fi
  done
done

export QBIT_BASE="$BASE" QBIT_COOKIE="$COOKIE" QBIT_DELETE="$DELETE" QBIT_GRACE_DAYS="$GRACE_DAYS"
python3 - <<'PYEOF'
import json, os, subprocess, time

base = os.environ["QBIT_BASE"]; cookie = os.environ["QBIT_COOKIE"]
delete = os.environ["QBIT_DELETE"] == "1"
grace_days = int(os.environ["QBIT_GRACE_DAYS"])
grace = time.time() - grace_days * 86400

ts = json.load(open("/tmp/opencode/qbit-cleanup-torrents.json"))
queue_hashes = set()
for app in ("radarr", "sonarr"):
    for line in open(f"/tmp/opencode/qbit-cleanup-{app}.json"):
        r = json.loads(line)
        if r.get("downloadId"): queue_hashes.add(r["downloadId"])

def payload_link_state(cpath):
    """returns (n_linked, n_total) of the torrent's content files on HOST paths"""
    host = cpath.replace("/srv/misc/torrents/", "/srv/Media/Torrents/", 1) \
        if cpath.startswith("/srv/misc/torrents/") else cpath
    linked = total = 0
    if os.path.isdir(host):
        for root, _, files in os.walk(host):
            for f in files:
                try:
                    total += 1
                    if os.stat(os.path.join(root, f)).st_nlink >= 2: linked += 1
                except OSError: pass
    else:
        try:
            total = 1
            linked = 1 if os.stat(host).st_nlink >= 2 else 0
        except OSError: total = 0
    return linked, total, host

keep, errored, backlog, library_gone, partial, unmanaged, young = [], [], [], [], [], [], []
for t in ts:
    name, cat = t["name"], t.get("category","")
    if not cat:
        unmanaged.append(t); continue                    # manual torrents: never touch
    if t["state"] == "missingFiles":
        errored.append(t); continue                       # payload already gone
    linked, total, host = payload_link_state(t.get("content_path",""))
    if total == 0:
        errored.append(t); continue                      # stat failed / nothing there
    if linked == total:
        keep.append(t); continue                          # fully in library: seed forever
    comp = t.get("completion_on") or 0
    if not comp or comp > grace:
        young.append(t); continue                         # fresh: give *arr time
    if 0 < linked < total:
        partial.append(t); continue                       # mixed: report only
    (backlog if t["hash"] in queue_hashes else library_gone).append(t)

gb = lambda l: sum(t["size"] for t in l)/1e9
print(f"== qbit-cleanup (grace {grace_days}d) - seeding GC per owner intent ==")
print(f"  KEEP seeding (in library via hardlink): {len(keep):5}  {gb(keep):8.0f} GB")
print(f"  remove: never-imported backlog:         {len(backlog):5}  {gb(backlog):8.0f} GB")
print(f"  remove: library copy deleted:           {len(library_gone):5}  {gb(library_gone):8.0f} GB")
print(f"  remove: errored/missingFiles entries:  {len(errored):5}  {gb(errored):8.0f} GB (bytes already freed)")
print(f"  report: partial (some eps upgraded):    {len(partial):5}  {gb(partial):8.0f} GB")
print(f"  report: fresh (<{grace_days}d, pending):          {len(young):5}  {gb(young):8.0f} GB")
print(f"  SKIP:   unmanaged (no category):        {len(unmanaged):5}  {gb(unmanaged):8.0f} GB")
for label, l in (("never-imported (in *arr queue, rejected)", backlog),
                 ("library-deleted (not in any queue)", library_gone)):
    if l:
        print(f"\n  -- {label} --")
        for t in sorted(l, key=lambda x: -x["size"])[:20]:
            print(f"    {t['size']/1e9:7.1f} GB  {t['name'][:72]}")
if partial:
    print(f"\n  -- partial payload (manual review) --")
    for t in sorted(partial, key=lambda x: -x["size"])[:10]:
        print(f"    {t['size']/1e9:7.1f} GB  {t['name'][:72]}")

print(f"\nmode: {'DELETE' if delete else 'DRY RUN'}")
to_remove = backlog + library_gone + errored
for t in to_remove:
    if delete:
        subprocess.run(["curl","-s","-X","POST",f"{base}/api/v2/torrents/delete",
            "-H",f"Referer: {base}/","-H",cookie,
            "--data-urlencode",f"hashes={t['hash']}",
            "--data-urlencode","deleteFiles=true"], check=True)
    else:
        print(f"    would remove {t['size']/1e9:7.1f} GB  {t['name'][:70]}")
if delete:
    print(f"\nDONE: removed {len(to_remove)} torrents "
          f"({len(backlog)} never-imported, {len(library_gone)} library-deleted, "
          f"{len(errored)} errored entries). Library hardlinks untouched.")
else:
    print(f"\n(dry run) --delete would remove {len(to_remove)} torrents; "
          f"KEEP set ({len(keep)} torrents) is never touched.")
PYEOF