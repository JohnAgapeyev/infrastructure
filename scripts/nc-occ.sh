#!/usr/bin/env bash
# occ wrapper for Nextcloud (qbit-api.sh precedent).
# Usage: ./scripts/nc-occ.sh <occ args...>
#   e.g. ./scripts/nc-occ.sh user:add --email a@b.c familymember
#        ./scripts/nc-occ.sh status
set -euo pipefail
kubectl -n cloud exec deploy/nextcloud -- runuser -u www-data -- php /var/www/html/occ "$@"
