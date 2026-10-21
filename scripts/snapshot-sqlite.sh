#!/usr/bin/env bash
# Consistent SQLite snapshots via the online backup API. Deployed to
# /srv/appdata/_scripts/snapshot-sqlite.sh and run as ExecStartPre by
# rclone-backup.service (root). Skips missing DBs gracefully.
#
# 2026-10-21 lesson: grafana/grafana.db hit "database is locked" at
# 00:00:29 -> rc=1 -> the ExecStartPre failure aborted the WHOLE
# rclone-backup unit (zero B2 upload that night) - one short writer
# lock must not kill the nightly. Every .backup now runs under a 15s
# busy_timeout (.timeout) so brief locks WAIT instead of failing; a
# persistent lock still fails loudly (rc=1: uploading a snapshot set
# with holes while the live copies are rclone-excluded would be worse
# than no upload).
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
  # AI phase: Hermes sessions/state live in one SQLite db (WAL in-pod on
  # ext4 hostPath is fine); the joplin CLI keeps its note database in the
  # profile (only written during the */5 job, but snapshot = consistent).
  [hermes/state.db]=/srv/appdata/hermes/state.db
  [joplin-cli/database.sqlite]=/srv/appdata/joplin-cli/profile/database.sqlite
)

mkdir -p "$DEST"
rc=0
for name in "${!DBS[@]}"; do
  db=${DBS[$name]}
  if [ -f "$db" ]; then
    mkdir -p "$DEST/$(dirname "$name")"
    if sqlite3 "$db" ".timeout 15000" ".backup $DEST/$name"; then
      echo "snapshot ok: $name"
    else
      echo "snapshot FAILED: $name" >&2
      rc=1
    fi
  fi
done

# OpenViking (AI phase): its SQLite files sit at unpredictable paths in
# the workspace (queuefs/usage-audit/...) - snapshot every *.db found and
# let the rclone exclude keep the live ones out of the sync (vector index
# *.db files are excluded with them; a corrupt index rebuilds via
# `ov reindex` - the source files under the workspace are what matter).
for db in $(find /srv/appdata/openviking -name '*.db' -type f 2>/dev/null); do
  rel=${db#/srv/appdata/openviking/}
  mkdir -p "$DEST/openviking/$(dirname "$rel")"
  if sqlite3 "$db" ".timeout 15000" ".backup $DEST/openviking/$rel"; then
    echo "snapshot ok: openviking/$rel"
  else
    echo "snapshot FAILED: openviking/$rel" >&2
    rc=1
  fi
done

# OpenClaw (OC phase): per-agent SQLite DBs at unpredictable paths
# (~/.openclaw/agents/<id>/agent/openclaw-agent.sqlite + the memory index)
# - snapshot every *.sqlite found; the rclone exclude keeps the live ones
# out of the sync. A corrupt/stale memory index rebuilds with
# `openclaw memory index --force` - the markdown source of truth
# (MEMORY.md, memory/*.md) rides the plain dir sync.
for db in $(find /srv/appdata/openclaw -name '*.sqlite' -type f 2>/dev/null); do
  rel=${db#/srv/appdata/openclaw/}
  mkdir -p "$DEST/openclaw/$(dirname "$rel")"
  if sqlite3 "$db" ".timeout 15000" ".backup $DEST/openclaw/$rel"; then
    echo "snapshot ok: openclaw/$rel"
  else
    echo "snapshot FAILED: openclaw/$rel" >&2
    rc=1
  fi
done

# Letta (LET phase): App Server local-backend state (agents, MemFS
# repositories) under /root/.letta at unpredictable paths - snapshot every
# *.db + *.sqlite found; the rclone exclude keeps the live ones out of the
# sync. VERIFY at go-live that the pinned image actually uses SQLite here
# (if it is plain JSON/files, the snapshots are harmless no-ops and the
# plain dir sync already covers everything).
for db in $(find /srv/appdata/letta \( -name '*.db' -o -name '*.sqlite' \) -type f 2>/dev/null); do
  rel=${db#/srv/appdata/letta/}
  mkdir -p "$DEST/letta/$(dirname "$rel")"
  if sqlite3 "$db" ".timeout 15000" ".backup $DEST/letta/$rel"; then
    echo "snapshot ok: letta/$rel"
  else
    echo "snapshot FAILED: letta/$rel" >&2
    rc=1
  fi
done
exit "$rc"
