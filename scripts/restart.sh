#!/usr/bin/env bash
# Usage: restart.sh <namespace> <deployment>
#   ./scripts/restart.sh media qbittorrent
set -euo pipefail
NS=${1:?namespace required}
DEPLOY=${2:?deployment required}
kubectl -n "$NS" rollout restart "deploy/$DEPLOY"
kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout=300s
