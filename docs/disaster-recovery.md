# Disaster recovery

(Filled in during Phase 8.)

## Scope

- Protected data: `/srv/appdata` (all app state) via the existing
  rclone -> Backblaze B2 `John-System-Backups` pipeline; media on
  `/srv/Media` is not backed up (irreplaceable-ness accepted; it is torrents).
- Disposable: k3s runtime (`/var/lib/rancher/k3s`), Prometheus TSDB,
  Jellyfin cache - all recreated from git + appdata.

## Rebuild procedure (draft)

1. Reinstall Arch, unlock + mount `/srv` (crypttab), restore users
   (`bootstrap/host/create-users.sh`) and permissions
   (`bootstrap/host/permissions.sh`).
2. `git clone` this repo; `sudo bash bootstrap/k3s/install.sh`.
3. `rclone copy Backblaze:John-System-Backups/appdata /srv/appdata`.
4. If a live SQLite DB is corrupt, replace it with the
   `/srv/appdata/_snapshots/<app>/<name>.db` copy.
5. `make apply-all`.
