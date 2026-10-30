#!/usr/bin/env bash
# fact-share.sh <slug> [file|-]
#
# Saves a deliberately neutral, curated fact into OpenViking at
#   viking://resources/general-facts/<YYYY-MM-DD>-<slug>.md
# via the documented content-write API (POST /api/v1/content/write),
# which creates parent dirs and refreshes semantic/vector indexes
# server-side. Facts here are read-only for other memory-isolated
# profiles (operator grants read ACLs); this profile owns writes.
# Credentials come from Hermes's own /opt/data/.env (OPENVIKING_API_KEY /
# OPENVIKING_ENDPOINT, written by `hermes memory setup`).
#
# Deployed to /opt/data/skills/fact-share/ (see operations.md "AI ops");
# the hermes image ships no curl - the image venv python does the call.
set -euo pipefail

usage="usage: fact-share.sh <slug> [file|-]"
slug=${1:?$usage}
src=${2:--}

# kebab-case only: the URI path must stay safe
case "$slug" in
  ""|*[!a-z0-9-]*|[.-]|[.-]*[.-]|[.-]) echo "invalid slug: '$slug' (use kebab-case)" >&2; exit 2 ;;
esac

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

uri="viking://resources/general-facts/$(date +%F)-${slug}.md"

FACT_ENDPOINT="$endpoint" FACT_KEY="$api_key" FACT_URI="$uri" \
FACT_CONTENT="$content" /opt/hermes/.venv/bin/python - <<'PY'
import json, os, sys, urllib.error, urllib.request

endpoint = os.environ["FACT_ENDPOINT"].rstrip("/")
payload = {
    "uri": os.environ["FACT_URI"],
    "content": os.environ["FACT_CONTENT"],
    "mode": "replace",
}
req = urllib.request.Request(
    endpoint + "/api/v1/content/write",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json", "X-API-Key": os.environ["FACT_KEY"]},
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
