# Disaster recovery

Verified baseline: nightly rclone -> B2 `John-System-Backups/appdata` with
consistent SQLite snapshots in `_snapshots/` (rehearsed with Prowlarr,
2026-09-14).

## Scope

- Protected: `/srv/appdata` (app state + snapshots) + the legacy
  `/srv/Backups` set (the existing pipeline). Media (`/srv/Media`) is NOT
  backed up by design - it is torrents.
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
5. `make apply-cluster && make apply-all`
   (kustomize first for namespaces + grafana-admin secret; then helm
   observability). Unbound host overrides (see PLAN 3.4) for `*.lan`.
6. Verify: `kubectl get pods -A`; log into Jellyfin/Radarr/Sonarr;
   ./scripts/qbit-verify-paths.sh (torrent count 519); browse
   http://grafana.lan.

## Rehearsal (done 2026-09-14, with Prowlarr)

- `rclone copy Backblaze:John-System-Backups/appdata/prowlarr <tmp>` ->
  compare with `/srv/appdata/prowlarr` (config.xml + db intact).
- Restore `_snapshots/bazarr/bazarr.db` into a scratch dir, open with
  sqlite3, dump a table: readable.

Re-run the rehearsal after any change to the backup pipeline.

## Single-app recovery (no full rebuild)

- Radarr/Sonarr/Prowlarr: restore `<app>` dir from B2 (or their own weekly
  zips in `<app>/Backups/`), `make apply-media`.
- Jellyfin: restore `/srv/appdata/jellyfin` from B2 + the pre-rename
  tarball (`/srv/Backups/migration-2026-09-13/jellyfin-pre-rename.tgz`)
  for a full-library fallback.
- qBittorrent: `/srv/appdata/qbittorrent/qBittorrent` (fastresume +
  categories); media tree itself is untouched.
- Grafana: `/srv/appdata/grafana` (or the grafana.db snapshot).
