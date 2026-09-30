#!/usr/bin/env bash
# Phase 9b: matter-server Docker -> k3s state migration (SUDO, ~1 min).
# - stops the Docker matter-server container (the only downtime; container
#   kept for rollback: docker compose start matter-server - the Docker data
#   dir is never modified, only copied)
# - rsyncs /home/john/docker/matter-server/data -> /srv/appdata/matter-server
#   (1.5 MB, root:root preserved - matter-server runs as root in k8s too;
#   contains the Matter FABRIC, which is irreplaceable)
# - belt-and-braces extra copy of the fabric to
#   /srv/Backups/migration-<date>/matter-fabric-copy-9b/
# The k3s Deployment (apps/home/matter-server) is applied by the agent
# afterwards with `make apply-home` - do NOT run that here.
# Run as root: sudo bash bootstrap/host/phase9b-migrate-matter.sh
set -euo pipefail

cd /srv/homeassistant
docker compose stop matter-server

state=$(docker inspect -f '{{.State.Status}}' matter-server)
if [ "$state" != exited ]; then
  echo "REFUSING: matter-server container is '$state', not stopped" >&2
  exit 1
fi

mkdir -p /srv/appdata/matter-server
rsync -aHAX /home/john/docker/matter-server/data/ /srv/appdata/matter-server/

# extra copy of the irreplaceable fabric (same pattern as Phase 0)
D=/srv/Backups/migration-$(date +%F)
mkdir -p "$D/matter-fabric-copy-9b"
rsync -aHAX /home/john/docker/matter-server/data/ "$D/matter-fabric-copy-9b/"

echo
echo "OK - homeassistant container is still stopped (untouched)."
echo "Next (agent): make apply-home"
docker ps -a --filter name=matter-server --format '{{.Names}}: {{.Status}}'
du -sh /srv/appdata/matter-server "$D/matter-fabric-copy-9b"
