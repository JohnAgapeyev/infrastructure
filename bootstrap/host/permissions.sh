#!/usr/bin/env bash
# Phase 0: metadata-only permission normalization under /srv/Media
# (~15k inodes: chgrp + chmod only, no data is read or written).
#
# TV dirs are sonarr:sonarr 755 and movie files radarr:radarr 644 today,
# which would block Bazarr/Sonarr group writes. After this: dirs 2775
# (setgid -> new files inherit group media), files 664.
#
# Run as root: sudo bash bootstrap/host/permissions.sh
set -euo pipefail

chgrp -R media /srv/Media
find /srv/Media -type d -exec chmod 2775 {} +
find /srv/Media -type f -exec chmod 664 {} +

# Optional hardening of non-media /srv trees (media pods never mount these).
# /srv/Backups becomes root:root 750 -> only root (rclone) and sudo access.
chmod 750 /srv/Backups /srv/DNR /srv/VMs /srv/Games

echo done
