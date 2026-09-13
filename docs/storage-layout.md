# Storage layout

Host: `nas`. One ext4 filesystem on LUKS RAID6 mounted at `/srv`
(device id 64515, shared by everything under `/srv` - hardlinks work anywhere
within it; `mv` within `/srv` is always an instant rename).

## Filesystems

| Mount | Device | FS | Size | Free |
|---|---|---|---|---|
| `/` | `RootVG-root` (LUKS on sda2, SSD) | ext4 | 232 GB | 157 GB |
| `/srv` | `NasVG-data` on `nascrypt` LUKS on md127 RAID6 (sdb1 sdc1 sdd1 sde1) | ext4 | 21.7 TB | 9.8 TB |

k3s runtime (`/var/lib/rancher/k3s`) lives on `/` (SSD) and is disposable.
All app state lives on `/srv` (RAID).

## Paths

- `/srv/Media/{Movies,TV,Anime,Porn,Torrents}` - media library; Torrents is
  the qBittorrent download tree (moved from `/srv/misc/torrents` in Phase 2;
  `/srv/misc/torrents` becomes a symlink).
- `/srv/Media/Torrents/completed/{movies,tv,anime,manual,torrents,porn}` -
  qBittorrent save paths; `.recycle` - arr recycle bin; `incomplete` - qB
  temp path (if enabled).
- `/srv/appdata/<app>` - app state (see below); `_snapshots/` - SQLite online
  backups; `_scripts/` - scripts deployed on the host (snapshot-sqlite.sh).
- Samba shares on the host point into `/srv/Media/*` and `/srv/misc`; they are
  unaffected by the migration.

## UIDs / GIDs

| User | UID | Primary GID | Notes |
|---|---|---|---|
| qbittorrent | 1005 | 1006 (qbittorrent) | exists; media supplementary |
| jellyfin | 1004 | 1005 | exists; media supplementary |
| radarr | 973 | 973 | exists; media supplementary |
| sonarr | 972 | 972 | exists; media supplementary |
| prowlarr | 959 | 1003 | created 2026-09-13 (auto-assigned) |
| bazarr | 971 | 971 (bazarr) | created 2026-09-13; NOT in media - pods use PGID=1003 |
| seerr | 958 | 1003 | created 2026-09-13 (auto-assigned) |
| shoko | 957 | 1003 | created 2026-09-13 (auto-assigned) |
| recyclarr | 956 | 1003 | created 2026-09-13 (auto-assigned) |
| unpackerr | 955 | 1003 | created 2026-09-13 (auto-assigned) |
| prometheus | 1000 | 1000 | in-image UID (chart default); host uid 1000 = john |
| grafana | 472 | 472 | in-image UID (chart default) |
| alertmanager | 1000 | 1000 | in-image UID (chart default) |

Plan's original UIDs 980-982 were taken (systemd users); owner chose auto
assignment at creation. `/srv/appdata/<app>` dirs are chowned `<user>:media`
(numeric ownership is what the pods see; for DR pin these UIDs in
`bootstrap/host/create-users.sh`).

All media pods: GID 1003 (`media`) via PGID/fsGroup, UMASK 002, setgid (2775)
dirs / group-writable (664) files under `/srv/Media` (normalized Phase 0).

## Hardlink rules

- Never copy media. Only `mv` within `/srv`, `chgrp`, `chmod`, `ln`.
- Before any `mv`: `stat -c %d SRC DEST_PARENT` must match (both 64515).
- Radarr/Sonarr must see the torrent dir and library dir through ONE hostPath
  (`/srv/Media` mounted at `/srv/Media`) so `link()` never crosses a mount.

## Capture results (Phase 0, 2026-09-13)

Full capture: `/tmp/opencode/capture.txt` (redacted). Highlights:

### qBittorrent (systemd, 5.2.3, User=qbittorrent Group=media UMask=002)

- **BT port P = 41045** (`Session\Port=41045`, tcp+udp; 22822 is sshd, 18555
  is go2rtc). `General\UseRandomPort=true` (legacy key; must be set false +
  `Session\UseRandomPort=false` during migration so the port is fixed).
- Resume storage: **fastresume files** (`torrents.db` ABSENT).
  **N = 519 fastresume / 519 .torrent** files in `BT_backup`.
- `Session\DefaultSavePath=/srv/misc/torrents/completed`;
  `Session\TempPathEnabled=true`, `Session\TempPath=/srv/misc/torrents/temp`
  (must be moved to `/srv/Media/Torrents/incomplete`, see PLAN 6.3);
  `Session\Preallocation=true` already.
- `Session\TorrentExportDirectory=/srv/misc/torrents/completed/torrents`
  (the ~4.5k .torrent exports; `Downloads\FinishedTorrentExportDir` same).
- WebUI: `Username=admin`, port 8080, `Address=*`,
  `HostHeaderValidation=true` with `ServerDomains=*` (any Host header OK),
  `AuthSubnetWhitelistEnabled=true` whitelist `10.0.0.0/24`,
  `LocalHostAuth=false`, **HTTPS enabled** (certs in root-only
  `/home/qbittorrent/cert.pem`/`key.pem`, NOT migrated -> set
  `WebUI\HTTPS\Enabled=false`; WebUI becomes plain HTTP).
- `Session\Tags=IPTorrents`. Queueing currently disabled
  (`Session\QueueingSystemEnabled=false`). Share limits: global ratio 10,
  share-limit action EnableSuperSeeding.
- **Categories** (`categories.json` + `Session\Categories`): `Anime` ->
  `/srv/Media/Anime`, `Movies` -> `/srv/misc/torrents/completed/movies/`,
  `Porn` -> `/srv/Media/Porn/`, `TV` -> `/srv/misc/torrents/completed/tv/`.
  REUSED as-is (torrents reference these names): `Movies`=Radarr category,
  `TV`=Sonarr TV category, `Anime`=anime-direct, `Porn` unchanged. NEW:
  `anime-sonarr` -> `/srv/Media/Torrents/completed/anime`, `manual` ->
  `/srv/Media/Torrents/completed/manual`.
- AnonymousMode=true, DHT/LSH/PeX disabled, trackerPort=9000
  (forwarding off).

### Jellyfin (systemd 10.11.11, jellyfin:jellyfin)

- Libraries: `Movies` `/srv/Media/Movies` (TMDb), `TV` `/srv/Media/TV`
  (TMDb), `Anime` `/srv/Media/Anime` (AniList+AniDB), `Collections`
  (internal). Realtime monitor ON, LUFS scan ON.
- `system.xml`: `ServerName` EMPTY (defaults to hostname = pod name -> pin
  `<ServerName>nas</ServerName>` during migration). `EnableMetrics=false`
  (enable in Dashboard after migration, for Phase 7 `/metrics`).
- `network.xml`: HTTP 8096 / HTTPS 8920 (HTTPS off), AutoDiscovery=true,
  `KnownProxies` EMPTY (set `10.42.0.0/16` in Dashboard after migration),
  `IgnoreVirtualInterfaces=true` incl. `veth`.
- `encoding.xml`: `HardwareAccelerationType=none`, no `EncoderAppPath` set
  (only `EncoderAppPathDisplay`), ffmpeg software transcoding.
- Plugins: AniDB 11.0.0.0, AniList 13.0.0.0 (+ configurations).
- Data sizes: `data` 14G, `metadata` 4.1G, `plugins` 404K, `root` 64K.

### Home Assistant (docker, 2025.12.4, host network)

- `.HA_VERSION`: **2025.12.4**. `configuration.yaml`: default_config + theme
  includes only.
- Integration domains: backup, go2rtc, google_translate, group, linkplay,
  matter, met, mobile_app, radio_browser, shopping_list, sun, zeroconf.
- go2rtc runs on host ports 18554 (localhost) / 18555 (likely HA go2rtc
  integration child process). Phase 9 concern.

### matter-server (docker, host network)

- Image `ghcr.io/matter-js/python-matter-server:stable`, digest
  `sha256:6827e352...aad3`. No version labels (compose image) - exact
  version to be determined at Phase 9 (e.g. `docker exec matter-server pip
  show python-matter-server`).
- Cmd: `--storage-path /data --paa-root-cert-dir /data/credentials`.
- Fabric data `/home/john/docker/matter-server/data` (extra copy taken in
  `/srv/Backups/migration-2026-09-13/matter-fabric-copy`).

### Boot / storage

- `/etc/crypttab`: `nascrypt /dev/md/nas:nas /etc/raid_keyfile` - keyfile
  unlock, NOT interactive. k3s drop-in (`After=srv.mount`,
  `RequiresMountsFor=/srv`) suffices; boot waits for mdadm + cryptsetup only.
- Cold copy taken: `/srv/Backups/migration-2026-09-13/appstate.tgz` (+ 14G
  jellyfin data was NOT re-tarred separately - it is inside appstate.tgz).

### Samba

- Shares: movies/tv/anime/porn -> `/srv/Media/*` (valid users @media, write
  list john torrents), temp -> `/srv/misc` (won't follow the torrents
  symlink - expected), games/vms/dnr/art unchanged. `create mask 0664`,
  `directory mask 0755`, `force create mode 0644` (SMB-created dirs are not
  setgid; media group write still works via `@media` write list + 664 files,
  new dirs 755 root group perms are tolerable).

### Verification (Phase 0 checklist)

- [x] users created (UIDs above), `/srv/appdata/*` chowned `<user>:media` 750
- [x] `/srv/Media` normalized: dirs `<owner>:media 2775`, files 664
- [x] `/srv/Backups/migration-2026-09-13/{appstate.tgz,matter-fabric-copy}`
- [x] capture.txt answers: P=41045, N=519, fastresume storage, paths, HA
      2025.12.4, matter digest
- [ ] Unbound host overrides `<svc>.lan` -> 10.0.0.4 (user, OPNsense)
