#!/usr/bin/env bash
# Phase 0: cold copy of all app state to /srv/Backups/migration-<date>/.
# Services keep running; each phase takes a fresh consistent copy with the
# service stopped. Run as root:
#
#   sudo bash bootstrap/host/cold-copy.sh
set -euo pipefail

D="/srv/Backups/migration-$(date +%F)"
mkdir -p "$D"

tar -C / -czf "$D/appstate.tgz" \
  home/qbittorrent/.config \
  home/qbittorrent/.local/share/qBittorrent \
  etc/jellyfin \
  var/lib/jellyfin \
  var/lib/radarr \
  var/lib/sonarr \
  var/lib/jackett \
  srv/homeassistant/config \
  home/john/docker/matter-server \
  etc/samba/smb.conf

# The Matter fabric is irreplaceable; keep an extra unpacked copy.
cp -a /home/john/docker/matter-server/data "$D/matter-fabric-copy"

echo "Wrote $D/appstate.tgz and $D/matter-fabric-copy"
