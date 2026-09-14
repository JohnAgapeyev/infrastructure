#!/usr/bin/env bash
# qBittorrent API helper: logs in once, sources creds from secrets/qbittorrent.env.
#   ./scripts/qbit-api.sh /api/v2/torrents/info | python3 -c '...'
set -euo pipefail
cd "$(dirname "$0")/.."
. secrets/qbittorrent.env
BASE="http://${QBIT_HOST:-nas}:8080"
LINE=$(curl -s -c - -H "Referer: $BASE/" \
  --data-urlencode "username=${QBIT_WEBUI_USER}" \
  --data-urlencode "password=${QBIT_WEBUI_PASS}" \
  "$BASE/api/v2/auth/login" | grep -E 'QBT_SID' | tail -1)
COOKIE_NAME=$(echo "$LINE" | awk '{print $6}')
COOKIE_VALUE=$(echo "$LINE" | awk '{print $7}')
[ -n "${COOKIE_VALUE:-}" ] || { echo "login failed" >&2; exit 1; }
exec curl -s -H "Referer: $BASE/" -H "Cookie: ${COOKIE_NAME}=${COOKIE_VALUE};" "${BASE}$*"
