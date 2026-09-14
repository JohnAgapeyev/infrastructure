#!/usr/bin/env bash
# Phase 8 (plan 12.1.3): DR rehearsal with Prowlarr.
# Verifies: B2 restore of one app + snapshot integrity, WITHOUT touching the
# live deployment. Run as root: sudo bash bootstrap/host/dr-rehearsal.sh
set -euo pipefail

WORK=$(mktemp -d /tmp/dr-rehearsal.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

echo "== 1. restore prowlarr from B2"
rclone copy Backblaze:John-System-Backups/appdata/prowlarr "$WORK/prowlarr" -P --exclude 'logs/**' 2>&1 | tail -2
echo "restored files: $(find "$WORK/prowlarr" -type f | wc -l)"
test -f "$WORK/prowlarr/config.xml" && echo "config.xml OK"

echo
echo "== 2. snapshot integrity (bazarr + jellyfin)"
rclone copy Backblaze:John-System-Backups/appdata/_snapshots/bazarr "$WORK/snap-bazarr" 2>&1 | tail -1
sqlite3 "$WORK/snap-bazarr/bazarr.db" "PRAGMA integrity_check;" | head -1
sqlite3 "$WORK/snap-bazarr/bazarr.db" "select count(*) from table_settings_languages;" | xargs echo "bazarr rows (languages):"
rclone copy Backblaze:John-System-Backups/appdata/_snapshots/jellyfin "$WORK/snap-jellyfin" 2>&1 | tail -1
sqlite3 "$WORK/snap-jellyfin/jellyfin.db" "PRAGMA integrity_check;" | head -1

echo
echo "== 3. live prowlarr config matches backup (API key identical)"
LIVE_KEY=$(grep -oE '<ApiKey>[^<]+' /srv/appdata/prowlarr/config.xml | cut -d'>' -f2)
BAK_KEY=$(grep -oE '<ApiKey>[^<]+' "$WORK/prowlarr/config.xml" | cut -d'>' -f2)
[ "$LIVE_KEY" = "$BAK_KEY" ] && echo "API keys match: ${LIVE_KEY:0:8}..." || { echo "MISMATCH"; exit 1; }

echo
echo "REHEARSAL PASSED"
