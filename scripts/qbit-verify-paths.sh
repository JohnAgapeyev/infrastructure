#!/usr/bin/env bash
# Phase 2 verification: torrent migration sanity via the qBittorrent WebUI
# API (/api/v2). Reads creds from secrets/qbittorrent.env.
#   ./scripts/qbit-verify-paths.sh
# Host source 10.0.0.4 is inside the 10.0.0.0/24 auth whitelist today, so the
# API answers even before login, but login is attempted regardless.
set -uo pipefail
cd "$(dirname "$0")/.."

EXPECTED=${EXPECTED:-519}   # torrent count N from Phase 0 capture

if [ -f secrets/qbittorrent.env ]; then
  # shellcheck disable=SC1091
  . secrets/qbittorrent.env
fi

HOST=${QBIT_HOST:-nas}
BASE="http://${HOST}:8080"
JAR=$(mktemp)
trap 'rm -f "$JAR"' EXIT

if [ -n "${QBIT_WEBUI_PASS:-}" ]; then
  # Referer header required: WebUI CSRF protection rejects bare POSTs.
  curl -s -c "$JAR" -H "Referer: $BASE/" --data-urlencode "username=${QBIT_WEBUI_USER:-admin}" \
    --data-urlencode "password=${QBIT_WEBUI_PASS}" \
    "$BASE/api/v2/auth/login" >/dev/null
fi

api() { curl -s -b "$JAR" -H "Referer: $BASE/" "$@"; }

echo "== version (expect 5.2.3) =="
api "$BASE/api/v2/app/version"; echo

echo "== transfer info (connection_status, speeds) =="
api "$BASE/api/v2/transfer/info"; echo

echo "== torrents: count / bad states / distinct save paths =="
TLIST=$(mktemp); trap 'rm -f "$JAR" "$TLIST"' EXIT
api "$BASE/api/v2/torrents/info" > "$TLIST"
python3 - "$EXPECTED" "$TLIST" <<'EOF'
import json, sys
expect, path = int(sys.argv[1]), sys.argv[2]
ts = json.load(open(path))
print("count:", len(ts), "expected:", expect, "->", "OK" if len(ts) == expect else "MISMATCH")
bad = [t for t in ts if t["state"] in ("missingFiles", "error")]
print("missing/error:", len(bad))
for t in bad[:10]:
    print("  BAD:", t["name"], t["state"])
paths = {}
for t in ts:
    paths.setdefault(t["save_path"], 0)
    paths[t["save_path"]] += 1
print("distinct save paths:", len(paths))
for p, c in sorted(paths.items()):
    print(f"  {c:4d}  {p}")
EOF

echo "== every distinct save_path exists inside the pod =="
python3 -c 'import json,sys; print("\n".join(sorted({t["save_path"] for t in json.load(open(sys.argv[1]))})))' "$TLIST" |
while IFS= read -r p; do
  if kubectl -n media exec deploy/qbittorrent -- test -d "$p" 2>/dev/null; then
    echo "OK  $p"
  else
    echo "MISSING IN POD: $p"
  fi
done

echo "== WebUI endpoints =="
for u in "http://nas:8080" "http://qbit.lan"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u/")
  echo "$u -> $code"
done
