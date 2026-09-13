#!/usr/bin/env bash
# Phase 0: create the media service users and the /srv/appdata tree.
#
# New users are created WITHOUT pinned UIDs (owner decision 2026-09-13);
# useradd assigns them from the system range. The assigned UIDs are recorded
# in docs/storage-layout.md after this script first runs and used as
# PUID/runAsUser in the app manifests. Pre-existing users keep their UIDs
# (qbittorrent 1005, jellyfin 1004, radarr 973, sonarr 972).
#
# NOTE for disaster recovery: a rebuilt host may auto-assign different UIDs.
# Before running this on a rebuilt host, pin the recorded UIDs below with
# `useradd -r -u <uid> -g media ...` (see docs/disaster-recovery.md).
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
mkdir -p /srv/appdata/{qbittorrent,jellyfin,jellyfin-cache,prowlarr,radarr,sonarr,bazarr,recyclarr,seerr,shoko,prometheus,grafana,alertmanager,_snapshots,_scripts}

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

# Host-side utility dirs (root-run snapshot script + snapshots).
chown root:media /srv/appdata/_snapshots /srv/appdata/_scripts

chmod 750 /srv/appdata/*

echo
echo "Assigned UIDs (record these in docs/storage-layout.md):"
getent passwd prowlarr bazarr seerr shoko recyclarr unpackerr
