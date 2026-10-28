#!/usr/bin/env bash
# Managed RocksDB backup trigger for Tuwunel (MX-3). Deployed to
# /srv/appdata/_scripts/snapshot-tuwunel.sh and run as a FOURTH
# ExecStartPre by rclone-backup.service (root) - the snapshot-{sqlite,
# postgres,mongo}.sh pattern, except this one is a TRIGGER: tuwunel
# owns the backup machinery (RocksDB BackupEngine = consistent ONLINE
# copy with verification and retention via database_backups_to_keep),
# and the only way to invoke it is the admin-room command
# "!admin server backup-database". So we send that message over the
# client-server API with a long-lived admin token (root-only env file,
# go-live step 6) and wait for the repo dir to change.
#
# The LIVE RocksDB tree (/srv/appdata/tuwunel) is EXCLUDED from the
# rclone sync (torn mid-write copies are useless - the librechat-mongo
# class); the managed backup repo in _snapshots/tuwunel/ IS synced and
# is the DB restore source. DR restore (docs/disaster-recovery.md):
#   kubectl -n ai scale deploy/tuwunel --replicas=0
#   kubectl apply -f apps/ai/tuwunel/restore-pod.yaml   # --restore-backup
#   kubectl -n ai delete pod tuwunel-restore
#   kubectl -n ai scale deploy/tuwunel --replicas=1
#
# Fails the whole backup unit if anything is off (token expired,
# homeserver down, backup never lands): a files-only backup with no
# current DB backup is a silent data hole (the postgres lesson).
set -uo pipefail

ENV_FILE=/srv/appdata/_scripts/tuwunel-backup.env
URL=https://matrix.home.jg-a.com
DEST=/srv/appdata/_snapshots/tuwunel

if [ ! -r "$ENV_FILE" ]; then
  # Rollout window: the drop-in is copied early in the go-live sequence
  # (it also carries the live-RocksDB exclude), but the env file can
  # only be created after the homeserver + admin account exist (step 6).
  # Before the DB has EVER been created there is nothing to back up (no
  # RocksDB CURRENT file) - skip loudly so the rest of the backup unit
  # proceeds. The moment a DB exists, a missing env file is a HARD
  # failure (no silent backup hole).
  if [ ! -e /srv/appdata/tuwunel/CURRENT ]; then
    echo "snapshot-tuwunel: no DB yet (rollout window) + no $ENV_FILE - skipping (create it at the MX go-live backup-env step, operations.md 'MX phase'; once the DB exists this becomes a hard failure)"
    exit 0
  fi
  echo "snapshot-tuwunel: $ENV_FILE missing but the DB exists - aborting" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"
: "${TUWUNEL_ADMIN_TOKEN:?TUWUNEL_ADMIN_TOKEN}"
: "${TUWUNEL_ADMIN_ROOM_ID:?TUWUNEL_ADMIN_ROOM_ID}"

REF=$(mktemp /tmp/tuwunel-backup-ref.XXXXXX)
trap 'rm -f "$REF"' EXIT

# Spec-form PUT (transaction id). m.text is what the admin-room command
# parser reads. 200 = the homeserver accepted the event; the command
# RESULT comes back as a room message (check "!admin server
# list-backups" in Element when debugging).
CODE=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
  -H "Authorization: Bearer $TUWUNEL_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"msgtype":"m.text","body":"!admin server backup-database"}' \
  "$URL/_matrix/client/v3/rooms/$TUWUNEL_ADMIN_ROOM_ID/send/m.room.message/rclone-$(date +%s)")
if [ "$CODE" != 200 ]; then
  echo "snapshot-tuwunel: admin-room send failed (HTTP $CODE - token expired? homeserver up? room ID right?) - aborting" >&2
  exit 1
fi

# A small personal DB backs up in seconds; 120s is generous. The repo
# dir changing after the command = the backup landed (the BackupEngine
# writes new files + updates its metadata).
for _ in $(seq 1 24); do
  sleep 5
  if [ -n "$(find "$DEST" -newer "$REF" -print -quit 2>/dev/null)" ]; then
    echo "snapshot ok: $DEST updated (managed backup created)"
    exit 0
  fi
done
echo "snapshot FAILED: $DEST unchanged 120s after the backup command - check '!admin server list-backups' in the admin room" >&2
exit 1
