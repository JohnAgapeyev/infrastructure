#!/usr/bin/env bash
# Usage: logs.sh <namespace> <deployment> [lines]
#   ./scripts/logs.sh media qbittorrent 200
set -euo pipefail
NS=${1:?namespace required}
DEPLOY=${2:?deployment required}
TAIL=${3:-200}
kubectl -n "$NS" logs "deploy/$DEPLOY" --tail="$TAIL"
