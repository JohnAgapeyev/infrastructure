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
| qbittorrent | 1005 | 1006 | exists |
| jellyfin | 1004 | 1005 | exists; media is supplementary |
| radarr | 973 | 973 | exists |
| sonarr | 972 | 972 | exists |
| prowlarr | TBD | 1003 | new |
| bazarr | TBD | 1003 | new |
| seerr | TBD | 1003 | new |
| shoko | TBD | 1003 | new |
| recyclarr | TBD | 1003 | new |
| unpackerr | TBD | 1003 | new |
| prometheus | 1000 | 1000 | chart default, hostPath dir owner |
| grafana | 472 | 472 | chart default, hostPath dir owner |
| alertmanager | 1000 | 1000 | chart default, hostPath dir owner |

NOTE: plan's UIDs 980-982 are TAKEN on the host (systemd-resolve,
systemd-network, systemd-journal-remote). Final assignment recorded here once
decided.

All media pods run with supplementary/effective GID 1003 (`media`), UMASK 002,
setgid (2775) dirs / group-writable (664) files under `/srv/Media`.

## Hardlink rules

- Never copy media. Only `mv` within `/srv`, `chgrp`, `chmod`, `ln`.
- Before any `mv`: `stat -c %d SRC DEST_PARENT` must match (both 64515).
- Radarr/Sonarr must see the torrent dir and library dir through ONE hostPath
  (`/srv/Media` mounted at `/srv/Media`) so `link()` never crosses a mount.

## Capture results (Phase 0, 2026-09-13)

(to be filled from `/tmp/opencode/capture.txt`)
