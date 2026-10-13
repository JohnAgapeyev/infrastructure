#!/usr/bin/env bash
# Phase 0: create the media service users and the /srv/appdata tree.
#
# New users are created WITHOUT pinned UIDs (owner decision 2026-09-13);
# useradd assigns them from the system range. Assigned UIDs are recorded in
# docs/storage-layout.md and used as PUID/runAsUser in the app manifests.
# Pre-existing users keep their UIDs (qbittorrent 1005, jellyfin 1004,
# radarr 973, sonarr 972).
#
# UIDs ASSIGNED 2026-09-13 (recorded for disaster recovery - pin these with
# `useradd -r -u <uid> -g media` when recreating on a rebuilt host):
#   prowlarr 959, bazarr 971 (primary group 971 `bazarr`, not media - pods
#   use PGID=1003), seerr 958, shoko 957, recyclarr 956, unpackerr 955.
#
# Run as root: sudo bash bootstrap/host/create-users.sh
set -euo pipefail

# New system users, primary group media (1003), no home dir, no login shell.
for name in prowlarr bazarr seerr shoko recyclarr unpackerr; do
  if ! id "$name" >/dev/null 2>&1; then
    useradd -r -g media -M -s /usr/bin/nologin "$name"
  fi
  getent passwd "$name"
done

# App state dirs on the RAID (all disposable-by-app, restorable from B2).
mkdir -p /srv/appdata/{qbittorrent,jellyfin,jellyfin-cache,prowlarr,radarr,sonarr,bazarr,recyclarr,seerr,shoko,prometheus,grafana,alertmanager,ntfy,_snapshots,_scripts}

# Per-app ownership (by name: uses whatever UID the host assigned/preserved).
for name in qbittorrent jellyfin prowlarr radarr sonarr bazarr recyclarr seerr shoko; do
  chown "${name}:media" "/srv/appdata/$name"
done
chown jellyfin:media /srv/appdata/jellyfin-cache

# Observability dirs are owned by the in-image UIDs the charts run as
# (defaults: prometheus 1000, grafana 472, alertmanager 1000 - re-verified
# against chart values in Phase 7).
chown 1000:1000 /srv/appdata/prometheus /srv/appdata/alertmanager
chown 472:472 /srv/appdata/grafana
# ntfy: upstream image has no USER -> runs as root; keep root:root (default).
# Holds the message cache + the provisioned user/token db (NOT disposable -
# see apps/observability/notify/ for the provisioning runbook).
chown 0:0 /srv/appdata/ntfy

# Host-side utility dirs (root-run snapshot script + snapshots).
chown root:media /srv/appdata/_snapshots /srv/appdata/_scripts

chmod 750 /srv/appdata/*

# Nextcloud (phase NC-0, 2026-10-13): the official image runs as www-data
# (in-image UID 33 - the grafana-472 precedent), group media; postgres uses
# its in-image UID 999. No new host users needed.
mkdir -p /srv/appdata/nextcloud/config /srv/appdata/nextcloud/custom_apps \
         /srv/appdata/nextcloud-data /srv/appdata/postgres
chown 33:media /srv/appdata/nextcloud/config /srv/appdata/nextcloud/custom_apps \
                /srv/appdata/nextcloud-data
chown 999:999 /srv/appdata/postgres
chmod 700 /srv/appdata/postgres   # postgres refuses group/world-accessible PGDATA

echo
echo "Assigned UIDs (record these in docs/storage-layout.md):"
getent passwd prowlarr bazarr seerr shoko recyclarr unpackerr
