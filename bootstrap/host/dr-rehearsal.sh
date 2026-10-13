#!/usr/bin/env bash
# Phase 8 (plan 12.1.3): DR rehearsal with Prowlarr.
# Verifies: B2 restore of one app + snapshot integrity, WITHOUT touching the
# live deployment. Run as root: sudo bash bootstrap/host/dr-rehearsal.sh
# NC-4 (2026-10-13): Nextcloud leg - the pg_dump restores from B2 and LOADS
# into a throwaway postgres; plus guards that the rclone exclusions hold
# (live PG cluster files and the arr live DBs must not be in B2).
set -euo pipefail

WORK=$(mktemp -d /tmp/dr-rehearsal.XXXXXX)
VERIFY_POD=""
cleanup() {
  rm -rf "$WORK"
  [ -n "$VERIFY_POD" ] && kubectl delete pod "$VERIFY_POD" --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT

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
echo "== 4. nextcloud: pg dump restores from B2 and loads (throwaway postgres)"
rclone copy Backblaze:John-System-Backups/appdata/_snapshots/nextcloud "$WORK/snap-nextcloud" 2>&1 | tail -1
test -f "$WORK/snap-nextcloud/nextcloud.sql.gz" && echo "dump present"
gunzip -t "$WORK/snap-nextcloud/nextcloud.sql.gz" && echo "gzip integrity OK"
VERIFY_POD="pg-verify-$RANDOM"
kubectl run "$VERIFY_POD" --image=postgres:18.6 --env=POSTGRES_PASSWORD=verify --restart=Never >/dev/null
for i in $(seq 1 30); do
  kubectl exec "$VERIFY_POD" -- pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 2
done
kubectl exec "$VERIFY_POD" -- psql -U postgres -c 'create database ncverify' >/dev/null
gunzip -c "$WORK/snap-nextcloud/nextcloud.sql.gz" | kubectl exec -i "$VERIFY_POD" -- psql -U postgres -d ncverify -q -v ON_ERROR_STOP=1 >/dev/null
echo "oc_users rows:    $(kubectl exec "$VERIFY_POD" -- psql -U postgres -d ncverify -t -A -c 'select count(*) from oc_users;')"
echo "oc_storages rows: $(kubectl exec "$VERIFY_POD" -- psql -U postgres -d ncverify -t -A -c 'select count(*) from oc_storages;')"
kubectl delete pod "$VERIFY_POD" --ignore-not-found >/dev/null
VERIFY_POD=""

echo
echo "== 5. exclusion guards: live DB files must NOT be in B2"
if rclone ls Backblaze:John-System-Backups/appdata/sonarr --include 'sonarr.db' --include 'logs.db' | grep -q .; then
  echo "FAIL: sonarr live DBs still in B2 (sync exclusion broken)"; exit 1
else
  echo "sonarr live DBs absent from B2: OK"
fi
if rclone lsf Backblaze:John-System-Backups/appdata/postgres 2>/dev/null | grep -q .; then
  echo "FAIL: postgres/ cluster files in B2"; exit 1
else
  echo "postgres/ absent from B2: OK"
fi
if rclone lsf Backblaze:John-System-Backups/appdata/jellyfin/Shokofin/VFS 2>/dev/null | grep -q .; then
  echo "FAIL: Shokofin VFS tree in B2"; exit 1
else
  echo "Shokofin VFS absent from B2: OK"
fi

echo
echo "REHEARSAL PASSED"
