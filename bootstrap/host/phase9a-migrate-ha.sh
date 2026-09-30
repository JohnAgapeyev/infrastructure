#!/usr/bin/env bash
# Phase 9a: Home Assistant Docker -> k3s state migration (SUDO, ~1 min).
# - stops the Docker homeassistant container (the only downtime; it stays
#   stopped, k3s HA takes over on the copied /config; container is kept for
#   rollback: docker compose start homeassistant)
# - rsyncs /srv/homeassistant/config -> /srv/appdata/home-assistant
#   (12 MB; root:root preserved - HA runs as root in k8s too; DB is copied
#   while stopped = consistent)
# The k3s Deployment (apps/home/home-assistant) is applied by the agent
# afterwards with `make apply-home` - do NOT run that here.
# Run as root: sudo bash bootstrap/host/phase9a-migrate-ha.sh
set -euo pipefail

cd /srv/homeassistant
docker compose stop homeassistant

state=$(docker inspect -f '{{.State.Status}}' homeassistant)
if [ "$state" != exited ]; then
  echo "REFUSING: homeassistant container is '$state', not stopped" >&2
  exit 1
fi

mkdir -p /srv/appdata/home-assistant
rsync -aHAX /srv/homeassistant/config/ /srv/appdata/home-assistant/

echo
echo "OK - matter-server is still running in Docker (untouched)."
echo "Next (agent): make apply-home"
docker ps --filter name=homeassistant --format '{{.Names}}: {{.Status}}'
du -sh /srv/appdata/home-assistant
