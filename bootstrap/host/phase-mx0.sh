#!/usr/bin/env bash
# MX-0 host prep (run with sudo). Creates the state dirs for the
# tuwunel Matrix homeserver (MX phase).
#
# Ownership (letta precedent): the jevolk/tuwunel image sets NO USER in
# its image config (verified from the registry image config,
# 2026-10-28) -> it runs as root -> all dirs 0:0. If a future image
# ever switches to a non-root user, the pod crash-loops on the RocksDB
# open (permission denied) - re-chown to that UID and re-run this.
#
# - /srv/appdata/tuwunel       - RocksDB database. The LIVE tree is
#                                EXCLUDED from the B2 sync (torn
#                                mid-write copies are useless - the
#                                librechat-mongo class); the DB
#                                restore source is the MANAGED backup
#                                repo below (MX-3).
# - /srv/appdata/tuwunel-media - media files, on a SEPARATE dir (D8)
#                                so the DB dir can be excluded
#                                wholesale while media syncs plainly
#                                (media IS the file restore source,
#                                librechat images/uploads class).
# - /srv/appdata/_snapshots/tuwunel - tuwunel's managed RocksDB backup
#                                repo (the deployment mounts it at
#                                /var/backups/tuwunel; retention is
#                                tuwunel's own database_backups_to_keep
#                                = 7).
set -euo pipefail
mkdir -p /srv/appdata/tuwunel /srv/appdata/tuwunel-media /srv/appdata/_snapshots/tuwunel
chown 0:0 /srv/appdata/tuwunel /srv/appdata/tuwunel-media /srv/appdata/_snapshots/tuwunel
chmod 750 /srv/appdata/tuwunel /srv/appdata/tuwunel-media /srv/appdata/_snapshots/tuwunel
ls -ld /srv/appdata/tuwunel /srv/appdata/tuwunel-media /srv/appdata/_snapshots/tuwunel
