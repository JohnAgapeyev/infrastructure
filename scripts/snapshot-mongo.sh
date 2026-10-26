#!/usr/bin/env bash
# Consistent MongoDB dump for LibreChat (LC phase). Deployed to
# /srv/appdata/_scripts/snapshot-mongo.sh and run as a THIRD ExecStartPre
# by rclone-backup.service (root; /usr/local/bin/kubectl is the k3s
# symlink) - the snapshot-postgres.sh pattern, same reasoning:
#
# The LIVE WiredTiger tree (/srv/appdata/librechat-mongo) is EXCLUDED
# from the rclone sync (see bootstrap/host/rclone-backup-dropin.conf):
# mid-write copies are torn and useless - THIS archive is the DB restore
# source, the same class as the excluded live snapshotted SQLite DBs.
#
# mongodump is MVCC-consistent (runs while the app serves, no locking).
# One archive per night, overwritten on re-runs - the B2 bucket lifecycle
# versions the uploads (same retention model as the other snapshot
# scripts). --archive on stdout = no temp files in the data dir.
#
# Fails the whole backup unit if mongo is unreachable: a files-only
# backup with no current dump is a silent data hole (postgres lesson).
#
# DR restore (rehearsal leg, docs/disaster-recovery.md):
#   kubectl -n ai exec -i deploy/librechat-mongo -- \
#     mongorestore --archive --drop < librechat-mongo.archive.gz
#   (gunzip first; --drop replaces the DB on an existing instance)
set -uo pipefail

KUBECTL=/usr/local/bin/kubectl
DEST=/srv/appdata/_snapshots/librechat
OUT="$DEST/librechat-mongo.archive.gz"

mkdir -p "$DEST"

if ! "$KUBECTL" -n ai exec deploy/librechat-mongo -- mongosh --quiet --eval 'db.adminCommand({ping: 1})' >/dev/null 2>&1; then
  echo "snapshot-mongo: librechat-mongo not ready - aborting" >&2
  exit 1
fi

if "$KUBECTL" -n ai exec deploy/librechat-mongo -- mongodump --archive --db LibreChat --quiet | gzip > "$OUT"; then
  echo "snapshot ok: $OUT ($(du -h "$OUT" | cut -f1))"
else
  echo "snapshot FAILED: $OUT" >&2
  exit 1
fi