#!/usr/bin/env bash
# Consistent SQLite snapshots via the online backup API. Deployed to
# /srv/appdata/_scripts/snapshot-sqlite.sh and run as ExecStartPre by
# rclone-backup.service (root). Skips missing DBs gracefully.
#
# Radarr/Sonarr/Prowlarr are NOT listed: they write their own weekly zips to
# <app>/Backups/. qBittorrent BT_backup is many small files, safe to copy
# live. Prometheus TSDB is disposable by decision.
set -uo pipefail

DEST=/srv/appdata/_snapshots

declare -A DBS=(
  [jellyfin/jellyfin.db]=/srv/appdata/jellyfin/data/jellyfin.db
  [seerr/db.sqlite3]=/srv/appdata/seerr/db/db.sqlite3
  [bazarr/bazarr.db]=/srv/appdata/bazarr/db/bazarr.db
  [shoko/JMMServer.db3]=/srv/appdata/shoko/Shoko.CLI/SQLite/JMMServer.db3
  [grafana/grafana.db]=/srv/appdata/grafana/grafana.db
  [home-assistant/home-assistant_v2.db]=/srv/appdata/home-assistant/home-assistant_v2.db
)

mkdir -p "$DEST"
rc=0
for name in "${!DBS[@]}"; do
  db=${DBS[$name]}
  if [ -f "$db" ]; then
    mkdir -p "$DEST/$(dirname "$name")"
    if sqlite3 "$db" ".backup $DEST/$name"; then
      echo "snapshot ok: $name"
    else
      echo "snapshot FAILED: $name" >&2
      rc=1
    fi
  fi
done
exit "$rc"
