#!/usr/bin/env bash
# qBittorrent seeding cleanup - frees array space WITHOUT losing library media.
#
# Background (2026-10-12 array-full incident, see docs/media-workflow.md):
# arr apps import via HARDLINK (torrent file and library file share one
# inode), so removing a torrent + its content from qBittorrent deletes only
# ONE link - the library copy survives untouched. Space is reclaimed only
# when the last link goes. Deleting imported torrents is therefore SAFE for
# the library, and is the main lever on this box: 19.8 TB sat in qBittorrent
# (1598 torrents); 9.1 TB of it was completed >90 days prior.
#
# A torrent is deletable only when ALL hold:
#   - ratio >= MIN_RATIO (env, default 1.0) - you got the seed back
#   - completed >= MIN_AGE_DAYS (env, default 90) ago
#   - qBittorrent state is seeding/paused-up (never downloading/errored)
#   - content_path is under /srv/Media/Torrents (never touches other data)
#   - its payload files are hardlinked into a library (links >= 2)
#
# Un-imported torrents (payload unique to the torrent dir) are NEVER deleted
# automatically - reported for manual import-or-drop. Un-imported content was
# 3.3 TB at analysis time (featurettes, subs, alternate releases Radarr
# upgraded past).
#
# Usage:
#   ./scripts/qbit-cleanup.sh              # DRY RUN (default): report only
#   ./scripts/qbit-cleanup.sh --delete     # actually delete + free space
#   MIN_RATIO=2.0 ./scripts/qbit-cleanup.sh
set -euo pipefail
cd "$(dirname "$0")/.."
. secrets/qbittorrent.env
BASE="http://${QBIT_HOST:-nas}:8080"
DELETE=0
[ "${1:-}" = "--delete" ] && DELETE=1

# login (same flow as qbit-api.sh)
LINE=$(curl -s -c - -H "Referer: $BASE/" \
  --data-urlencode "username=${QBIT_WEBUI_USER}" \
  --data-urlencode "password=${QBIT_WEBUI_PASS}" \
  "$BASE/api/v2/auth/login" | grep -E 'QBT_SID' | tail -1)
COOKIE_NAME=$(echo "$LINE" | awk '{print $6}')
COOKIE_VALUE=$(echo "$LINE" | awk '{print $7}')
[ -n "${COOKIE_VALUE:-}" ] || { echo "login failed" >&2; exit 1; }
COOKIE="Cookie: ${COOKIE_NAME}=${COOKIE_VALUE};"
qbit() { curl -s -H "Referer: $BASE/" -H "$COOKIE" "$@"; }

qbit "$BASE/api/v2/torrents/info" > /tmp/opencode/qbit-torrents.json

export QBIT_BASE="$BASE" QBIT_COOKIE_HEADER="$COOKIE" QBIT_DELETE="$DELETE" \
       MIN_RATIO="${MIN_RATIO:-1.0}" MIN_AGE_DAYS="${MIN_AGE_DAYS:-90}"
python3 - <<'PYEOF'
import json, os, subprocess, sys, time

ts = json.load(open("/tmp/opencode/qbit-torrents.json"))
min_ratio = float(os.environ["MIN_RATIO"])
min_age_days = int(os.environ["MIN_AGE_DAYS"])
delete = os.environ["QBIT_DELETE"] == "1"
base = os.environ["QBIT_BASE"]
cookie = os.environ["QBIT_COOKIE_HEADER"]
cutoff = time.time() - min_age_days * 86400

SEEDING = {"stalledUP","uploading","forcedUP","pausedUP","stoppedUP"}
deletable, unimported, skipped = [], [], []
for t in ts:
    if t.get("state","") not in SEEDING:
        skipped.append(t); continue
    comp = t.get("completion_on") or 0
    # eligible = completed >= MIN_AGE_DAYS ago (completion_on in unix seconds;
    # 0 = unknown/never-completed -> keep)
    if not comp or comp > cutoff: skipped.append(t); continue
    if (t.get("ratio") or 0) < min_ratio: skipped.append(t); continue
    cpath = t.get("content_path","")
    if not cpath: skipped.append(t); continue
    # qBittorrent reports POD paths; on this host the torrent dir is mounted
    # in the pod at /srv/misc/torrents (fastresume path compat) - translate
    # to the real host path for the hardlink check.
    host_path = cpath
    if cpath.startswith("/srv/misc/torrents/"):
        host_path = "/srv/Media/Torrents/" + cpath[len("/srv/misc/torrents/"):]
    if not host_path.startswith("/srv/Media/Torrents/"): skipped.append(t); continue
    try:
        shared = 0
        if os.path.isdir(host_path):
            for root, _, files in os.walk(host_path):
                for f in files:
                    if os.stat(os.path.join(root, f)).st_nlink >= 2:
                        shared += 1
        else:
            shared = 1 if os.stat(host_path).st_nlink >= 2 else 0
    except OSError:
        skipped.append(t); continue
    (deletable if shared else unimported).append(t)

gb = lambda l: sum(t["size"] for t in l)/1e9
print(f"== qBittorrent cleanup (ratio>={min_ratio}, age>={min_age_days}d) ==")
print(f"  deletable (imported + hardlinked): {len(deletable):5}  {gb(deletable):8.0f} GB")
print(f"  UN-IMPORTED (manual review):       {len(unimported):5}  {gb(unimported):8.0f} GB")
print(f"  kept (active/young/low-ratio):      {len(skipped):5}  {gb(skipped):8.0f} GB")
print()
if unimported:
    print("  top un-imported (content exists ONLY in the torrent dir):")
    for t in sorted(unimported, key=lambda x: -x["size"])[:15]:
        print(f"    {t['size']/1e9:7.1f} GB  {t['name'][:80]}")
    print()
print(f"mode: {'DELETE' if delete else 'DRY RUN'}")
for t in deletable:
    if delete:
        subprocess.run(["curl","-s","-X","POST",f"{base}/api/v2/torrents/delete",
            "-H","Referer: {}/".format(base),"-H",cookie,
            "--data-urlencode",f"hashes={t['hash']}",
            "--data-urlencode","deleteFiles=true"], check=True)
    else:
        print(f"    would delete {t['size']/1e9:7.1f} GB  {t['name'][:70]}")
if delete:
    print(f"\nDONE: deleted {len(deletable)} imported torrents; library hardlinks unaffected")
else:
    print(f"\n(dry run) --delete would free {gb(deletable):.0f} GB")
PYEOF