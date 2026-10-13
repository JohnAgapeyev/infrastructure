#!/usr/bin/env bash
# Consistent PostgreSQL dump for Nextcloud (phase NC-3). Deployed to
# /srv/appdata/_scripts/snapshot-postgres.sh and run as a SECOND ExecStartPre
# by rclone-backup.service (root; /usr/local/bin/kubectl is the k3s symlink).
#
# The LIVE PGDATA (/srv/appdata/postgres) is EXCLUDED from the rclone sync
# (see bootstrap/host/rclone-backup-dropin.conf): live cluster files are
# useless as a copy - THIS dump is the DB restore source, the same reasoning
# as the excluded live snapshotted SQLite DBs in snapshot-sqlite.sh.
#
# pg_dump is MVCC-consistent (runs while the app serves, no locking).
# One dump per night, overwritten on re-runs - the B2 bucket lifecycle
# versions the uploads (same retention model as snapshot-sqlite.sh).
#
# Fails the whole backup unit if postgres is unreachable: a files-only
# backup with no current DB dump is a silent data hole.
set -uo pipefail

KUBECTL=/usr/local/bin/kubectl
DEST=/srv/appdata/_snapshots/nextcloud
OUT="$DEST/nextcloud.sql.gz"

mkdir -p "$DEST"

if ! "$KUBECTL" -n cloud exec deploy/postgres -- pg_isready -U nextcloud -d nextcloud >/dev/null 2>&1; then
  echo "snapshot-postgres: postgres not ready - aborting" >&2
  exit 1
fi

if "$KUBECTL" -n cloud exec deploy/postgres -- pg_dump -U nextcloud nextcloud | gzip > "$OUT"; then
  echo "snapshot ok: $OUT ($(du -h "$OUT" | cut -f1))"
else
  echo "snapshot FAILED: $OUT" >&2
  exit 1
fi