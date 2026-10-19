#!/usr/bin/env bash
# brain-save.sh <topic> <slug> [file|-]
#
# Saves a markdown note into OpenViking at
#   viking://~/resources/brain/<topic>/<YYYY-MM-DD>-<slug>.md
# via the documented content-write API (POST /api/v1/content/write), which
# creates parent dirs and refreshes semantic/vector indexes server-side.
# Credentials come from Hermes's own /opt/data/.env (OPENVIKING_API_KEY /
# OPENVIKING_ENDPOINT, written by `hermes memory setup`).
#
# Deployed to /opt/data/skills/brain-save/ (see operations.md "AI ops");
# the hermes image ships no curl - the image venv python does the call.
set -euo pipefail

usage="usage: brain-save.sh <topic> <slug> [file|-]"
topic=${1:?$usage}
slug=${2:?$usage}
src=${3:--}

# kebab-case only: the URI path must stay safe
for v in "$topic" "$slug"; do
  case "$v" in
    ""|*[!a-z0-9-]*|[.-]|[.-]*[.-]|[.-]) echo "invalid token: '$v' (use kebab-case)" >&2; exit 2 ;;
  esac
done

if [ "$src" = "-" ]; then
  content=$(cat)
else
  content=$(cat "$src")
fi
[ -n "$content" ] || { echo "empty note body" >&2; exit 2; }

env_file=/opt/data/.env
getenv() {
  grep -E "^$1=" "$env_file" 2>/dev/null | tail -1 | cut -d= -f2-
}
api_key=$(getenv OPENVIKING_API_KEY)
[ -n "$api_key" ] || { echo "OPENVIKING_API_KEY not set in $env_file (run hermes memory setup openviking)" >&2; exit 3; }
endpoint=$(getenv OPENVIKING_ENDPOINT)
endpoint=${endpoint:-http://openviking.ai.svc.cluster.local:1933}

uri="viking://~/resources/brain/${topic}/$(date +%F)-${slug}.md"

BRAIN_ENDPOINT="$endpoint" BRAIN_KEY="$api_key" BRAIN_URI="$uri" \
BRAIN_CONTENT="$content" /opt/hermes/.venv/bin/python - <<'PY'
import json, os, sys, urllib.error, urllib.request

endpoint = os.environ["BRAIN_ENDPOINT"].rstrip("/")
payload = {
    "uri": os.environ["BRAIN_URI"],
    "content": os.environ["BRAIN_CONTENT"],
    "mode": "replace",
}
req = urllib.request.Request(
    endpoint + "/api/v1/content/write",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json", "X-API-Key": os.environ["BRAIN_KEY"]},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        body = json.load(r)
except urllib.error.HTTPError as e:
    print(f"OpenViking HTTP {e.code}: {e.read().decode(errors='replace')[:500]}", file=sys.stderr)
    sys.exit(1)
if body.get("status") != "ok":
    print(f"OpenViking error: {body}", file=sys.stderr)
    sys.exit(1)
print(body["result"]["uri"])
PY
