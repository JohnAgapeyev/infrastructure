# Disaster recovery

Verified baseline: nightly rclone -> B2 `John-System-Backups/appdata` with
consistent SQLite snapshots in `_snapshots/` (rehearsed with Prowlarr,
2026-09-14; extended with the Nextcloud pg_dump leg, 2026-10-13).

## Scope

- Protected: `/srv/appdata` (app state + snapshots) + the legacy
  `/srv/Backups` set (the existing pipeline). Media (`/srv/Media`) is NOT
  backed up by design - it is torrents.
- Protected for Nextcloud (NC phase): `/srv/appdata/nextcloud` (config),
  `/srv/appdata/nextcloud-data` (user files incl. family photos, trashbin,
  versions) and the DB via the consistent dump
  `_snapshots/nextcloud/nextcloud.sql.gz` (the live `postgres/` cluster
  files are excluded from rclone - the dump is the ONLY DB restore source).
- NOT protected by design (regenerable): sonarr/radarr/prowlarr live DBs
  (their own weekly zips in `<app>/Backups/` are synced and are the
  restore source), `jellyfin/Shokofin/VFS/**` (Shokofin regenerates it
  from Shoko), `nextcloud-data/appdata_*/**` (instance cache + previews).
- AI phase: `/srv/appdata/hermes` (config/.env/sessions/memories/skills;
  live `state.db` excluded, snapshot in `_snapshots/hermes/`) and
  `/srv/appdata/openviking` (ov.conf, ovcli.conf, workspace source files)
  are protected; `openviking/**/*.db` (queue/audit DBs AND the vector
  index) is excluded live - snapshots exist in `_snapshots/openviking/`
  and a stale index rebuilds with `ov reindex` (docs: reindex uses the
  stored source files). `joplin-export/**` is regenerable (next */5 job
  run rebuilds it) and NOT protected.
- Disposable: k3s runtime (`/var/lib/rancher/k3s`, SSD), Prometheus TSDB,
  Jellyfin cache. All recreated from git + appdata.
- The Matter fabric (`/srv/appdata/matter-server`, Phase 9) is also kept
  unpacked in `/srv/Backups/migration-2026-09-13/matter-fabric-copy`.

## Rebuild procedure

1. Reinstall Arch (baseline packages + docker for nothing anymore, helm),
   restore LUKS: `/etc/crypttab` needs
   `nascrypt /dev/md/nas:nas /etc/raid_keyfile` (keyfile from the old
   system - keep a copy somewhere safe!).
2. Restore users and permissions BEFORE starting apps:
   `sudo bash bootstrap/host/create-users.sh` (pin UIDs per
   docs/storage-layout.md) + `sudo bash bootstrap/host/permissions.sh`.
3. Install k3s: `sudo bash bootstrap/k3s/install.sh`; copy kubeconfig
   (`~/.kube/config`); `sudo pacman -S --needed helm`.
4. Restore state:
   `rclone copy Backblaze:John-System-Backups/appdata /srv/appdata -P`
   then `sudo chown -R <per storage-layout.md> /srv/appdata/*` (users'
   UIDs are pinned, ownership survives if UIDs match).
   NOTE: restore `_snapshots/` too - if a live DB is corrupt, replace the
   live file with `sqlite3 _snapshots/<app>/<name>.db ".recover"` output
   or a plain copy of the snapshot.
   Nextcloud DB: do NOT restore `postgres/` (it is not in B2 anyway) -
   `make apply-cloud` starts postgres with an EMPTY PGDATA, then import:
   `gunzip -c /srv/appdata/_snapshots/nextcloud/nextcloud.sql.gz |
   kubectl -n cloud exec -i deploy/postgres -- psql -v ON_ERROR_STOP=1
   -U nextcloud -d nextcloud`
   and `kubectl -n cloud exec deploy/nextcloud -- runuser -u www-data --
   php /var/www/html/occ files:scan --all`. If the deployed image tag is
   NEWER than the dump's version, also run `./scripts/nc-occ.sh upgrade`
   (subdir-mount instances cannot self-detect the version gap - see
   operations.md quirks).
5. `make apply-cluster && make apply-all`
   (kustomize first for namespaces + grafana-admin secret; then helm
   observability). Unbound wildcard host override `*.home.jg-a.com` -> 10.0.0.4 (see tls.md); `make install-cert-manager` before `make apply-cluster` for cert-manager CRDs.
6. Verify: `kubectl get pods -A`; log into Jellyfin/Radarr/Sonarr;
   ./scripts/qbit-verify-paths.sh (torrent count 519); browse
   https://grafana.home.jg-a.com and https://nextcloud.home.jg-a.com.

## Rehearsal (done 2026-09-14, with Prowlarr; re-run 2026-10-13 after the
NC backup-pipeline changes: pg_dump leg + exclusion guards all PASS)

- `rclone copy Backblaze:John-System-Backups/appdata/prowlarr <tmp>` ->
  compare with `/srv/appdata/prowlarr` (config.xml + db intact).
- Restore `_snapshots/bazarr/bazarr.db` into a scratch dir, open with
  sqlite3, dump a table: readable.

Re-run the rehearsal after any change to the backup pipeline.

## Single-app recovery (no full rebuild)

- Radarr/Sonarr/Prowlarr: restore `<app>` dir from B2 (or their own weekly
  zips in `<app>/Backups/` - the LIVE DBs are excluded from the sync), 
  `make apply-media`.
- Jellyfin: restore `/srv/appdata/jellyfin` from B2 + the pre-rename
  tarball (`/srv/Backups/migration-2026-09-13/jellyfin-pre-rename.tgz`)
  for a full-library fallback. The `Shokofin/VFS` tree regenerates from
  Shoko on its own.
- qBittorrent: `/srv/appdata/qbittorrent/qBittorrent` (fastresume +
  categories); media tree itself is untouched.
- Grafana: `/srv/appdata/grafana` (or the grafana.db snapshot).
- Nextcloud: `kubectl -n cloud scale deploy/nextcloud --replicas=0`;
  restore `/srv/appdata/nextcloud` + `/srv/appdata/nextcloud-data` from
  B2; wipe `/srv/appdata/postgres` ONLY if the DB is what broke (it is NOT
  in B2 - recreate it empty); `make apply-cloud` (postgres comes up with
  an empty PGDATA); import the dump (no-owner format - loads cleanly into
  a fresh cluster; ON_ERROR_STOP makes a partial import loud instead of
  silent):
  `gunzip -c /srv/appdata/_snapshots/nextcloud/nextcloud.sql.gz |
  kubectl -n cloud exec -i deploy/postgres -- psql -v ON_ERROR_STOP=1
  -U nextcloud -d nextcloud`;
  if the deployed image tag is newer than the dump, `./scripts/nc-occ.sh
  upgrade` next (subdir-mount instances cannot self-detect the gap - see
  operations.md quirks);
  scale nextcloud back up; `occ files:scan --all` once Ready. Trashbin and
  file versions ride the data dir restore. If restoring into a RUNNING
  instance, `occ maintenance:mode --on` first.
- AI phase, openviking: restore `/srv/appdata/openviking` from B2
  (includes ov.conf with the root + OpenRouter keys; _snapshots/openviking
  holds consistent copies of its *.db files), `make apply-ai`. A stale or
  corrupt vector index rebuilds from the stored source files:
  `ov reindex viking:// --mode semantic_and_vectors` (admin key, or per
  scope via Studio).
- AI phase, hermes: restore `/srv/appdata/hermes` from B2 (live state.db
  excluded - replace with `_snapshots/hermes/state.db` if it is what
  broke), `make apply-ai`. If `/opt/data/.env` keys were lost, they are
  recorded in `secrets/*.env`; worst case re-run the first-run steps
  (operations.md "AI ops") - sessions/memory files ride the dir restore.
- AI phase, joplin-export: nothing to restore - `/srv/appdata/joplin-cli`
  (profile) is in B2, `/srv/appdata/joplin-export` regenerates on the
  next job run.
