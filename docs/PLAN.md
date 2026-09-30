# Migration Plan: native/Docker services on `nas` -> single-node k3s

Status: PLAN ONLY. Nothing in this document has been executed. This file is the
single reference for a later implementation session. Read it fully before doing
anything.

Progress (2026-09-30): Phases 0-8 done (see `git log`). Phase 9: 9.0
(networkd) verified 25/25; 9a Home Assistant verified in k3s
(http://ha.lan + http://nas:8123; Docker container stopped as rollback).
NEXT: 9b Matter Server (a later day), then Docker removal - RESUME FROM
`docs/phase9-handoff.md`.

Origin: derived from the ChatGPT session "Homelab K3s Recommendations"
(https://chatgpt.com/share/6aa6e591-bed8-83e8-860f-8538013f7f2e) plus a live
inventory of the host taken on 2026-09-13, plus decisions made with the owner
(John) in the planning conversation. Where this document and the ChatGPT
session disagree, this document wins.

---

## 0. Ground rules for the implementer

The implementer is expected to be a lower-cost model. Follow these literally.

1. NEVER copy media. Anything under `/srv/Media` or `/srv/misc/torrents` may
   only be `mv`'d within `/srv` (same filesystem = instant rename), `chgrp`'d,
   `chmod`'d, or `ln`'d. Never `cp`, `rsync`, `tar`, or cross-filesystem `mv`
   media. Before any `mv`, run `stat -c %d SRC DEST_PARENT` and confirm both
   numbers are identical.
2. App state directories are small (MBs to a few GB) and MAY be copied with
   `rsync -aHAX`.
3. The implementer has NO sudo. Every privileged command is written into a
   script under `bootstrap/host/` or printed in a block marked
   `### SUDO (user runs)`. The implementer then STOPS and waits for the user to
   confirm the block was run before continuing.
4. Pin image versions to the version currently running when migrating
   existing state (Jellyfin `10.11.11`, qBittorrent `5.2.3`, Home Assistant
   `2025.12.4`). Never migrate state onto an OLDER version. Upgrade only after
   migration is verified. No `:latest` or `:stable` tags anywhere in git.
5. Same absolute paths inside containers as on the host for media:
   `/srv/Media` -> `/srv/Media`. Never remap to `/data`, `/media`, etc.
6. Keep existing UIDs: qbittorrent 1005, jellyfin 1004, radarr 973,
   sonarr 972. GID for every media app is 1003 (`media`). `UMASK=002`.
7. `replicas: 1` and `strategy: type: Recreate` for every stateful app.
8. Every phase ends with the verification checklist passing. The old systemd
   unit / Docker container is only disabled AFTER verification and never
   uninstalled in the same phase. Do not `pacman -R` anything until Phase 9.
9. `git commit` after each phase: `phase N: <summary>`.
10. Volumes are plain `hostPath` (`type: Directory`). No PV/PVC indirection,
    no Longhorn/Rook/NFS, no operators beyond kube-prometheus-stack.
11. Disable every in-app auto-updater. Updates come only from git (Section 12).
12. When unsure about a fact stated here, verify it on the host with read-only
    commands before acting. Do not guess.

---

## 1. Discovered current architecture (2026-09-13)

### 1.1 Host
- Hostname `nas`, Arch Linux, kernel 7.2.4, 8 cores, 31 GiB RAM, 2 GiB swap.
- GPU: NVIDIA GT 1030 (GP108) on `nouveau`. GP108 has NO NVENC encoder. Hardware
  transcoding is impossible; Jellyfin uses software transcoding. Out of scope.
- cgroup v2. No firewall active (nftables/iptables/firewalld/ufw all inactive).
- Network: `enp5s0` 10.0.0.4/16 + global IPv6 (Telus). Router/DNS: OPNsense at
  10.0.0.2, search domain `lan`. Docker bridges 172.17/16, 172.18/16 exist.
  k3s defaults (pods 10.42.0.0/16, services 10.43.0.0/16) do not overlap.
- Docker 29.8 + docker-compose 5.5 installed (used only by HA + Matter).
- Arch `containerd 2.3.5`, `runc 1.5.1`, `iptables 1.8.13` are Docker deps
  only; k3s does not use them.

### 1.2 Storage (this drives every path decision)
| Mount | Device | FS | Size | Free |
|---|---|---|---|---|
| `/` | `RootVG-root` (LUKS on sda2, SSD) | ext4 | 232 GB | 157 GB |
| `/boot` | sda1 | vfat | 512 MB | |
| `/srv` | `NasVG-data` on `nascrypt` LUKS on `md127` RAID6 (4x 10.9 TB: sdb1 sdc1 sdd1 sde1) | ext4 | 21.7 TB | 9.8 TB |

`/srv` is ONE ext4 filesystem. Hardlinks work anywhere within it. Hardlinks are
ALREADY in use: 237 hardlinked files in Movies, 1927 in TV, 2671 under
torrents. Linux `link()` returns EXDEV if source and destination are on
different *mounts*, even of the same filesystem. Therefore every container that
creates hardlinks (Radarr, Sonarr) must see the torrent dir and the library dir
through ONE hostPath mount.

Media tree (apparent sizes):
- `/srv/Media/Movies` 3.2 TB, 212 folders, Radarr-style `Title (Year)/`, files
  `-rw-r--r-- radarr:radarr`, plus Jellyfin-written `movie.nfo`.
- `/srv/Media/TV` 4.2 TB, 31 folders. 22 Sonarr-style
  (`Breaking Bad/Season 1/Breaking Bad (2008) - S01E01 - ....mkv`), the rest raw
  dumps: `Peaky.Blinders.S01..S06.1080p.BluRay.x265-RARBG` (6 separate
  folders), `The Flash S01-S07 br 10bit ddp hevc-d3g`, `The Flash S08 ...`,
  `The Flash S09 web hevc-d3g`, `The Sopranos S01-S06 web hevc-d3g`,
  `Frasier (1993) Season 1-11 ...`, `MASH - Martinis and Medicine Complete Collection`.
- `/srv/Media/Anime` 1.6 TB, 144 entries, 138 owned `qbittorrent:media`
  (qBittorrent saves anime DIRECTLY here). 104 of 132 folders are flat,
  release-group-named (`[Erai-raws] Overlord - 01 ~ 13 [1080p]...`). TVDB-style
  parsing fails on these; this is the metadata pain point.
- `/srv/Media/Porn` empty directory (large dirent), qBittorrent category `porn`,
  Samba share `[porn]`. Carried over unchanged, no arr integration.
- `/srv/misc/torrents` 7.1 TB: `completed/{movies (209), tv (187), porn,
  torrents (4568 .torrent export files), MASH..., [Raizel]..., The Flash S09...,
  The Sopranos...}` plus ~80 loose `.torrent` files. Owner `qbittorrent:media`.
- Other `/srv` dirs (Backups, DNR, VMs, Games, Sync, Art, misc, ...) are
  personal and NOT mounted into any pod.

### 1.3 Services
| Service | Version | Runs as | State | Ports | Status / notes |
|---|---|---|---|---|---|
| qbittorrent-nox (systemd) | 5.2.3 | qbittorrent(1005):media(1003), umask 002 | `/home/qbittorrent/.config/qBittorrent`, `/home/qbittorrent/.local/share/qBittorrent` (root-only readable) | 8080 web; BT port unknown (22822 or 18555 seen listening) | running |
| jellyfin (systemd) | 10.11.11 | jellyfin(1004) | `/var/lib/jellyfin` (data), `/etc/jellyfin` (config), `/var/cache/jellyfin` | 8096 tcp, 7359 udp, 1900 udp | running; libraries at `/srv/Media/*`; ServerName `nas` |
| radarr (systemd) | 6.2.1 | radarr(973):media | `/var/lib/radarr` | 7878 | running; DB EMPTY (0 movies, no root folder, no indexers, no download client); auth "disabled for local addresses" (leaks API key to LAN); log level debug |
| sonarr (systemd) | 4.0.19 | sonarr(972):media | `/var/lib/sonarr` | 8989 | DISABLED; DB (Nov 2024) also EMPTY |
| jackett (systemd) | 0.24 | jackett(974) | `/var/lib/jackett` | 9117 | running; indexers 1337x, eztv, nyaasi, torrentscsv, ehentai; `AllowExternal: true` |
| homeassistant (docker compose `/srv/homeassistant/docker-compose.yaml`) | 2025.12.4 | root | `/srv/homeassistant/config` (11 MB) | 8123 | host network |
| matter-server (same compose) | `ghcr.io/matter-js/python-matter-server:stable` | root | `/home/john/docker/matter-server/data` (1.5 MB, contains the Matter fabric) + `/run/dbus` ro | 5580 | host network |
| samba (systemd) | 4.24 | root | `/etc/samba/smb.conf` | 139/445 | shares `[movies] [tv] [anime] [porn]` -> `/srv/Media/*`, `[temp]` -> `/srv/misc`, others. STAYS ON HOST. |
| syncthing@john | 2.1.5 | john | | 8384, 22000 | out of scope |
| rclone-backup.timer | | root | `/srv/Backups` -> Backblaze B2 `John-System-Backups` | | existing backup pipeline; B2 bucket already has lifecycle (versioning) rules |

Radarr and Sonarr databases are genuinely empty: nothing to restore. The
libraries on disk are the source of truth and are rebuilt via Library Import.

Listening ports observed: 22, 139/445 (smb), 5580 (matter), 8096 (jellyfin),
8123 (HA), 7878 (radarr), 8080 (qbit web), 9117 (jackett), 22822 (unknown,
likely qbit BT), 18554 (localhost) / 18555 (unknown), 41045 (unknown),
5353 mdns, 1900 ssdp, 7359 jellyfin discovery.

---

## 2. Decisions (final)

| Topic | Decision | Rationale |
|---|---|---|
| App state location | `/srv/appdata/<app>` on the RAID | Owner rejected splitting state onto the SSD (fragile, size-constrained). Accept HDD SQLite performance. Only k3s runtime (`/var/lib/rancher/k3s`) stays on SSD; it is disposable. |
| Media mount | One hostPath `/srv/Media` -> `/srv/Media`. Torrent data moves to `/srv/Media/Torrents` | Single mount satisfies hardlinks; SMB shares inside `/srv/Media` unaffected. |
| qBittorrent path compatibility | (A) primary: additionally mount `/srv/Media/Torrents` at `/srv/misc/torrents` inside the qbit pod; Radarr/Sonarr use Remote Path Mapping `/srv/misc/torrents/` -> `/srv/Media/Torrents/`. (B) optional later: rewrite fastresume paths. | Zero risk to ~4.5k torrents' stored save paths. |
| UIDs | Keep per-service host UIDs; GID 1003 for all; setgid dirs | No chown of 9 TB tree needed; only a metadata-only group/mode normalization. |
| Anime metadata | Shoko Server + Shokofin (VFS) | Matches by file hash against AniDB; ignores folder/filename layout. |
| Quality upgrades | Single Radarr + single Sonarr, TRaSH profiles via Recyclarr, upgrades allowed to Remux-2160p cutoff | Owner chose simplicity over dual 1080p/4K instances. |
| Rename existing media | YES, rename everything to new naming with provider IDs | Owner accepted possible Jellyfin re-match; take backup first. |
| VPN | None | Current behaviour. |
| Indexers | Prowlarr (+ FlareSolverr) replaces Jackett | Native arr sync, aggregate search. |
| Request front-end | Seerr (`ghcr.io/seerr-team/seerr`) | Successor of Jellyseerr/Overseerr. |
| Extras | FlareSolverr, Recyclarr, Bazarr, Unpackerr | Owner selected. |
| Ingress | Traefik (k3s bundled) with `<svc>.lan` names via OPNsense Unbound host overrides, plain HTTP; legacy host ports 8096/8080 kept via LoadBalancer (klipper servicelb) | Existing TV/phone clients keep working. |
| Observability | `kube-prometheus-stack` via a thin umbrella Helm chart | Standardized; upstream dashboards/rules; ServiceMonitor per target; Grafana sidecar ConfigMap dashboards (built-in feature of the Grafana chart). |
| Alerting | Alertmanager deployed with a null receiver; phone+email receivers DEFERRED | Owner wants functional stability first. |
| Backups | Extend existing rclone->B2 job with `/srv/appdata`; SQLite online-backup snapshots pre-step; NO restic | Owner rejected restic; B2 lifecycle rules already provide versioning. |
| Dependency updates | GitHub Dependabot (`docker` ecosystem on k8s manifests, `helm` on Chart.yaml) | Built into GitHub; owner preferred it over Renovate. |
| k3s install/upgrade | `get.k3s.io` script with pinned `INSTALL_K3S_VERSION`; NEVER the AUR package | Decouples k3s from `pacman -Syu`. |
| Secrets | gitignored `secrets/*.env` consumed by kustomize `secretGenerator`; `*.env.example` committed | Simple; SOPS optional later. |
| Explicitly out | multi-node, etcd, MetalLB, Cilium, service mesh, Argo/Flux, Loki (deferred), NetFlow/Akvorado, Velero, Prometheus history backup, blue/green | Per ChatGPT session; single failure domain. |

---

## 3. Target layout

### 3.1 Repository (`/home/john/code/infrastructure`, GitHub `JohnAgapeyev/infrastructure`)
```
infrastructure/
├── README.md
├── Makefile                          # status, apply-<ns>, logs, restart wrappers
├── .github/dependabot.yml
├── docs/
│   ├── PLAN.md                       # this file
│   ├── architecture.md
│   ├── storage-layout.md             # host paths, UIDs, hardlink rules, capture results
│   ├── operations.md                 # runbook + updating (Section 12)
│   ├── media-workflow.md             # Seerr->arr->qbit->Jellyfin, manual import, anime
│   └── disaster-recovery.md
├── bootstrap/
│   ├── k3s/config.yaml               # -> /etc/rancher/k3s/config.yaml
│   ├── k3s/install.sh                # pinned K3S_VERSION; install AND upgrade path
│   ├── k3s/k3s.service.d-override.conf   # After=srv.mount RequiresMountsFor=/srv
│   └── host/{capture-state.sh,create-users.sh,permissions.sh,phase2-move.sh,...}
├── cluster/
│   ├── kustomization.yaml
│   └── namespaces.yaml               # media, home, observability
├── apps/
│   ├── media/{qbittorrent,jellyfin,prowlarr,flaresolverr,radarr,sonarr,bazarr,unpackerr,recyclarr,seerr,shoko}/
│   │      each: kustomization.yaml deployment.yaml service.yaml [ingress.yaml] [configmap.yaml]
│   ├── home/{home-assistant,matter-server}/
│   └── observability/
│       ├── kube-prometheus-stack/{Chart.yaml,values.yaml,.helmignore}
│       ├── exporters/{smartctl,exportarr-*,qbittorrent-exporter,servicemonitors}/
│       ├── dashboards/*.yaml         # ConfigMaps labelled grafana_dashboard: "1"
│       └── rules/prometheusrule.yaml
├── secrets/
│   ├── *.env.example                 # committed
│   └── *.env                         # gitignored
└── scripts/
    ├── status.sh restart.sh logs.sh
    ├── qbit-verify-paths.sh
    ├── qbit-rewrite-fastresume.py    # optional (B)
    └── snapshot-sqlite.sh
```

### 3.2 Host directories
- `/srv/appdata/<app>` for: qbittorrent, jellyfin, jellyfin-cache, prowlarr,
  radarr, sonarr, bazarr, recyclarr, seerr, shoko, prometheus, grafana,
  alertmanager, home-assistant (Phase 9), matter-server (Phase 9),
  `_snapshots/`, `_scripts/`.
- `/srv/Media/{Movies,TV,Anime,Porn,Torrents}`.
- `/srv/Media/Torrents/completed/{movies,tv,anime,manual,torrents,porn,...}`
  (`movies`, `tv`, `torrents`, `porn` already exist after the move; `anime`,
  `manual` are new). `/srv/Media/Torrents/incomplete` only if qbit temp path
  is enabled.
- `/srv/misc/torrents` becomes a host symlink -> `/srv/Media/Torrents`.

### 3.3 Users (host, created Phase 0)
| User | UID | GID | Used by |
|---|---|---|---|
| qbittorrent | 1005 (exists) | 1003 | qbittorrent pod |
| jellyfin | 1004 (exists) | 1003 | jellyfin pod |
| radarr | 973 (exists) | 1003 | radarr, exportarr-radarr |
| sonarr | 972 (exists) | 1003 | sonarr, exportarr-sonarr |
| prowlarr | 980 | 1003 | prowlarr |
| bazarr | 981 | 1003 | bazarr |
| seerr | 982 | 1003 | seerr |
| shoko | 983 | 1003 | shoko |
| recyclarr | 984 | 1003 | recyclarr |
| unpackerr | 985 | 1003 | unpackerr |
(Verify the UIDs 980-985 are free with `getent passwd <uid>` before creating.)

### 3.4 Service endpoints
| App | Cluster DNS (namespace `media` unless noted) | Ingress host | Legacy host port kept |
|---|---|---|---|
| qbittorrent | `qbittorrent.media.svc.cluster.local:8080` | `qbit.lan` | 8080 (LoadBalancer); BT port `P` tcp+udp via pod `hostPort` |
| jellyfin | `jellyfin.media.svc.cluster.local:8096` | `jellyfin.lan` | 8096 (LoadBalancer); 7359/udp hostPort |
| prowlarr | `prowlarr...:9696` | `prowlarr.lan` | - |
| flaresolverr | `flaresolverr...:8191` | - | - |
| radarr | `radarr...:7878` | `radarr.lan` | - |
| sonarr | `sonarr...:8989` | `sonarr.lan` | - |
| bazarr | `bazarr...:6767` | `bazarr.lan` | - |
| seerr | `seerr...:5055` | `seerr.lan` | - |
| shoko | `shoko...:8111` | `shoko.lan` | - |
| grafana | `observability-grafana.observability.svc:80` (name depends on release) | `grafana.lan` | - |
| prometheus | `...-prometheus.observability.svc:9090` | `prometheus.lan` | - |
| alertmanager | `...-alertmanager.observability.svc:9093` | `alertmanager.lan` | - |
| home-assistant | hostNetwork | `ha.lan` (optional) | 8123 |
| matter-server | hostNetwork | - | 5580 |

User action (once): OPNsense -> Services -> Unbound DNS -> Host Overrides: A
records `qbit jellyfin prowlarr radarr sonarr bazarr seerr shoko grafana
prometheus alertmanager ha` in domain `lan` -> `10.0.0.4`.

---

## 4. Phase 0 - Inventory, safety copies, host prep (no downtime)

Goal: capture config the implementer cannot read, take cold copies, normalize
permissions, scaffold repo, wire Dependabot.

1. Write `bootstrap/host/capture-state.sh` (read-only; redact values of keys
   matching `Password|PBKDF2|ApiKey|Token|Secret`). It prints:
   - `/home/qbittorrent/.config/qBittorrent/qBittorrent.conf` (all keys; of
     special interest `Session\DefaultSavePath`, `Session\TempPath`,
     `Session\TempPathEnabled`, `Session\Port`, `Session\UseRandomPort`,
     `Session\ResumeDataStorageType`, `Session\TorrentExportDirectory`,
     `Session\FinishedTorrentExportDirectory`, `Session\SubcategoriesEnabled`,
     `WebUI\Port`, `WebUI\Address`, `WebUI\HostHeaderValidation`,
     `WebUI\LocalHostAuth`, `WebUI\AuthSubnetWhitelist*`),
     `categories.json`, `watched_folders.json` if present;
     `ls /home/qbittorrent/.local/share/qBittorrent/BT_backup | grep -c fastresume`
     and whether `torrents.db` exists (SQLite resume storage).
   - `/etc/jellyfin/{system,network,encoding}.xml`; `du -sh /var/lib/jellyfin/*`;
     `ls /var/lib/jellyfin/plugins`; every `/var/lib/jellyfin/root/default/*/options.xml`
     (library names, paths, enabled providers).
   - `/srv/homeassistant/config/configuration.yaml`; list of integration
     `domain` values from `.storage/core.config_entries`; `.HA_VERSION`.
   - `docker inspect matter-server --format '{{.Config.Image}}'` and the image
     digest/labels to determine the exact python-matter-server version.
   - `ss -tulpn` as root (identifies the owner of 22822/18555 -> BT port `P`).
   - `cat /etc/crypttab` (how `nascrypt` is unlocked at boot; needed for the
     k3s mount-ordering drop-in).
   ### SUDO (user runs): `sudo bash bootstrap/host/capture-state.sh > /tmp/opencode/capture.txt`
   Implementer records the results in `docs/storage-layout.md` (redacted).
2. ### SUDO - cold copy of all app state (services still running; a consistent
   copy is taken again per phase with the service stopped):
   ```
   D=/srv/Backups/migration-$(date +%F); sudo mkdir -p $D
   sudo tar -C / -czf $D/appstate.tgz home/qbittorrent/.config home/qbittorrent/.local/share/qBittorrent etc/jellyfin var/lib/jellyfin var/lib/radarr var/lib/sonarr var/lib/jackett srv/homeassistant/config home/john/docker/matter-server etc/samba/smb.conf
   sudo cp -a /home/john/docker/matter-server/data $D/matter-fabric-copy   # irreplaceable; extra copy
   ```
3. ### SUDO - `bootstrap/host/create-users.sh`: `useradd -r -u <uid> -g media -M -s /usr/bin/nologin <name>`
   for prowlarr bazarr seerr shoko recyclarr unpackerr (table 3.3). Then
   `mkdir -p /srv/appdata/{qbittorrent,jellyfin,jellyfin-cache,prowlarr,radarr,sonarr,bazarr,recyclarr,seerr,shoko,prometheus,grafana,alertmanager,_snapshots,_scripts}`
   and `chown <uid>:1003` each, `chmod 750`. prometheus/grafana/alertmanager
   are chowned to the UIDs the charts run as (Prometheus 1000, Grafana 472,
   Alertmanager 1000 by default) - verify in chart values at Phase 7.
4. ### SUDO - `bootstrap/host/permissions.sh` (metadata-only, ~15k inodes):
   ```
   chgrp -R media /srv/Media
   find /srv/Media -type d -exec chmod 2775 {} +
   find /srv/Media -type f -exec chmod 664 {} +
   chmod 750 /srv/Backups /srv/DNR /srv/VMs /srv/Games      # hardening, optional
   ```
   Rationale: TV dirs `sonarr:sonarr 755` and movie files `radarr:radarr 644`
   would block Bazarr/Sonarr writes. Setgid makes new files inherit `media`.
5. Scaffold the repo (Section 3.1), `Makefile`, `.gitignore` additions
   (`secrets/*.env`, `*.kubeconfig`, `charts/`, `Chart.lock` optional).
6. `.github/dependabot.yml` (Section 12.3). User installs nothing; Dependabot
   is built into GitHub. Confirm it is enabled under repo Settings ->
   Code security.
7. User creates the Unbound host overrides (3.4).

Verify: `getent passwd prowlarr bazarr seerr shoko recyclarr unpackerr`;
`stat -c '%U:%G %a' /srv/Media/*/ /srv/Media/TV/*/ | awk '{print $1" "$2}' | sort | uniq -c`
shows only `...:media 2775`; `dig +short jellyfin.lan @10.0.0.2` -> `10.0.0.4`;
`/tmp/opencode/capture.txt` answers: BT port `P`, resume storage type,
default/temp save paths, torrent count, HA version, matter-server version.

---

## 5. Phase 1 - k3s bootstrap (no downtime)

1. `bootstrap/k3s/config.yaml`:
   ```yaml
   write-kubeconfig-mode: "0644"
   node-name: nas
   # keep bundled traefik, servicelb, local-storage, coredns, metrics-server
   ```
2. `bootstrap/k3s/install.sh`:
   ```bash
   #!/usr/bin/env bash
   set -euo pipefail
   K3S_VERSION="v1.35.X+k3s1"   # look up current stable at https://github.com/k3s-io/k3s/releases ; pin it here
   install -D -m 0644 "$(dirname "$0")/config.yaml" /etc/rancher/k3s/config.yaml
   curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
   install -D -m 0644 "$(dirname "$0")/k3s.service.d-override.conf" /etc/systemd/system/k3s.service.d/override.conf
   systemctl daemon-reload
   ```
   `k3s.service.d-override.conf`:
   ```ini
   [Unit]
   After=srv.mount
   RequiresMountsFor=/srv
   ```
   (`/srv` is LUKS; k3s must not start before it is mounted or every hostPath
   pod fails. If crypttab unlock is interactive at boot, k3s simply waits.)
3. ### SUDO: `sudo bash bootstrap/k3s/install.sh`; then
   `mkdir -p ~/.kube && sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config && sudo chown john:john ~/.kube/config`.
   `sudo pacman -S helm`. Use `kubectl` = the symlink the installer creates to
   `k3s kubectl` (do NOT install Arch's `kubectl`).
4. `kubectl apply -k cluster/` (namespaces media, home, observability).
5. Smoke test: deploy `traefik/whoami` (pinned tag) in `media` with Ingress
   `whoami.lan`; `curl -s http://whoami.lan | head -1` returns. Delete it.
6. Verify Traefik owns host 80/443 (`ss -tlnp | grep -E ':80 |:443 '`) and
   klipper-lb DaemonSet pods exist (`kubectl -n kube-system get pods | grep svclb`).
7. Write `docs/operations.md` skeleton: `kubectl get pods -A`,
   `kubectl -n media logs deploy/<x> --tail=200`,
   `kubectl -n media rollout restart deploy/<x>`,
   `kubectl -n media scale deploy/<x> --replicas=0`, `journalctl -u k3s -e`.

Rollback: `sudo /usr/local/bin/k3s-uninstall.sh`. Nothing else changed.

---

## 6. Phase 2 - Torrent data move + qBittorrent -> k3s (highest-risk media step, ~15 min downtime)

Preconditions: Phase 0 capture done; known: BT port `P`, resume storage type,
default/temp save path, categories + paths, torrent count `N`, WebUI creds in
`secrets/qbittorrent.env`.

1. `apps/media/qbittorrent/deployment.yaml`:
   - image `lscr.io/linuxserver/qbittorrent:<tag for 5.2.3, or the nearest NEWER tag if 5.2.3 is gone>`
   - env `PUID=1005 PGID=1003 UMASK=002 TZ=America/Vancouver WEBUI_PORT=8080 TORRENTING_PORT=P`
   - volumes: hostPath `/srv/appdata/qbittorrent` -> `/config`;
     hostPath `/srv/Media` -> `/srv/Media`;
     hostPath `/srv/Media/Torrents` -> `/srv/misc/torrents`  (compat mount A)
   - ports: 8080; `P/TCP` and `P/UDP` each with `hostPort: P`
   - probes: `tcpSocket 8080` initially; switch to `httpGet /api/v2/app/version`
     after step 6 enables localhost auth bypass
   - `strategy: Recreate`; Service `type: LoadBalancer` port 8080; Ingress `qbit.lan`
2. `bootstrap/host/phase2-move.sh` ### SUDO:
   ```bash
   set -euo pipefail
   systemctl stop qbittorrent.service
   [ "$(stat -c %d /srv/misc/torrents)" = "$(stat -c %d /srv/Media)" ]   # same fs or abort
   mv /srv/misc/torrents /srv/Media/Torrents                              # rename, instant
   ln -s /srv/Media/Torrents /srv/misc/torrents                           # host convenience symlink
   mkdir -p /srv/Media/Torrents/completed/{anime,manual}
   chown qbittorrent:media /srv/Media/Torrents/completed/{anime,manual}
   chmod 2775 /srv/Media/Torrents/completed/{anime,manual}
   mkdir -p /srv/appdata/qbittorrent/qBittorrent
   rsync -aHAX /home/qbittorrent/.config/qBittorrent/ /srv/appdata/qbittorrent/qBittorrent/
   rsync -aHAX /home/qbittorrent/.local/share/qBittorrent/ /srv/appdata/qbittorrent/qBittorrent/   # BT_backup/ or torrents.db
   chown -R 1005:1003 /srv/appdata/qbittorrent
   ```
   LinuxServer layout is `/config/qBittorrent/qBittorrent.conf` and
   `/config/qBittorrent/BT_backup` (they set XDG_CONFIG_HOME and XDG_DATA_HOME
   both to `/config`), so the two rsyncs merge into one directory correctly.
3. Edit `/srv/appdata/qbittorrent/qBittorrent/qBittorrent.conf` (### SUDO or
   via a script the user runs): `WebUI\Address=*`, `WebUI\Port=8080`,
   `Session\Port=P`, `Session\UseRandomPort=false`,
   `Session\DefaultSavePath=/srv/Media/Torrents/completed`; if
   `Session\TempPathEnabled=true` set `Session\TempPath=/srv/Media/Torrents/incomplete`
   and create that dir (owner 1005:1003). If `WebUI\HostHeaderValidation=true`
   add `WebUI\ServerDomains=qbit.lan`. Do NOT touch `categories.json` (paths
   still resolve through compat mount A).
4. `kubectl apply -k apps/media/qbittorrent`; watch `kubectl -n media logs -f deploy/qbittorrent`.
   Expect no flood of "missing files"; torrents should resume without a full
   recheck (rename preserved mtimes).
5. `scripts/qbit-verify-paths.sh` (logs in with WebUI creds; uses `/api/v2`):
   - torrent count == `N`
   - `[.[]|select(.state=="missingFiles" or .state=="error")]|length == 0`
   - every distinct `save_path` exists in-pod:
     `kubectl -n media exec deploy/qbittorrent -- test -d "<path>"`
   - `http://nas:8080` and `http://qbit.lan` load
   - connection status icon = connectable (OPNsense NAT for `P` -> 10.0.0.4 unchanged)
   - upload > 0 within a few minutes
6. WebUI settings: "Bypass authentication for clients on localhost" ON;
   "Bypass authentication for clients in whitelisted IP subnets" ON with
   `10.42.0.0/16` (arr apps still send creds; exporters need it). Categories:
   `radarr` -> `/srv/Media/Torrents/completed/movies`, `tv-sonarr` ->
   `.../completed/tv`, `anime-sonarr` -> `.../completed/anime`, `manual` ->
   `.../completed/manual`, `anime-direct` -> `/srv/Media/Anime`. If the capture
   shows existing categories with the same purpose, REUSE them (torrents
   reference category names) and only add the missing ones. Torrent content
   layout Original; pre-allocate ON; queueing max active downloads 5, max
   active torrents 20; copy `.torrent` files for finished to
   `/srv/Media/Torrents/completed/torrents`.
7. ### SUDO: `sudo systemctl disable qbittorrent.service`. Keep `/home/qbittorrent`.
8. Optional ### SUDO: add `[torrents] path=/srv/Media/Torrents valid users=@media`
   to smb.conf and `smbcontrol all reload-config`. (`[temp]` share of `/srv/misc`
   will not follow the symlink outside the share; that is expected.)

Rollback: `kubectl -n media scale deploy/qbittorrent --replicas=0`; ### SUDO
`sudo rm /srv/misc/torrents && sudo mv /srv/Media/Torrents /srv/misc/torrents && sudo systemctl start qbittorrent`.

Optional cleanup (B), only after Phases 3-6 are stable:
`scripts/qbit-rewrite-fastresume.py`: scale qbit to 0; back up
`/srv/appdata/qbittorrent/qBittorrent/BT_backup`; for each `*.fastresume`
bdecode and replace prefix `/srv/misc/torrents` -> `/srv/Media/Torrents` in
keys `save_path`, `qBt-savePath`, `qBt-downloadPath`; for SQLite mode update
`torrents.target_save_path`, `download_path`, and the bencoded
`libtorrent_resume_data` blob; rewrite `categories.json`; scale up; rerun
step 5; then remove compat mount A and the arr Remote Path Mappings.

---

## 7. Phase 3 - Jellyfin -> k3s (~10 min downtime)

1. `apps/media/jellyfin/deployment.yaml`:
   - image `jellyfin/jellyfin:10.11.11` (official image; exact current version)
   - `securityContext: runAsUser: 1004, runAsGroup: 1003, fsGroup: 1003`
   - volumes: hostPath `/srv/appdata/jellyfin` -> `/config`;
     hostPath `/srv/appdata/jellyfin-cache` -> `/cache`;
     hostPath `/srv/Media` -> `/srv/Media` (read-write: Jellyfin writes nfo/images today)
   - env `JELLYFIN_PublishedServerUrl=http://jellyfin.lan`, `TZ`
   - ports 8096 tcp; 7359 udp with `hostPort: 7359`
   - probe `httpGet /health` 8096; resources request cpu 500m / mem 1Gi, limit mem 6Gi
   - `strategy: Recreate`; Service `type: LoadBalancer` 8096; Ingress `jellyfin.lan`
   Official image layout: datadir=/config, configdir=/config/config,
   cachedir=/cache, logdir=/config/log. Arch layout maps as:
   `/var/lib/jellyfin/*` -> `/srv/appdata/jellyfin/`,
   `/etc/jellyfin/*` -> `/srv/appdata/jellyfin/config/`,
   `/var/cache/jellyfin/*` -> `/srv/appdata/jellyfin-cache/`.
   `/etc/jellyfin/jellyfin.env` (Arch `--webdir/--ffmpeg` flags) is NOT copied.
   In `config/encoding.xml` clear `EncoderAppPath` if it is set (image has
   ffmpeg at `/usr/lib/jellyfin-ffmpeg/ffmpeg`, autodetected); hardware
   acceleration must be `none`.
2. ### SUDO:
   ```
   systemctl stop jellyfin
   rsync -aHAX /var/lib/jellyfin/ /srv/appdata/jellyfin/
   mkdir -p /srv/appdata/jellyfin/config && rsync -aHAX /etc/jellyfin/ /srv/appdata/jellyfin/config/
   rsync -aHAX /var/cache/jellyfin/ /srv/appdata/jellyfin-cache/
   rm -f /srv/appdata/jellyfin/config/jellyfin.env
   chown -R 1004:1003 /srv/appdata/jellyfin /srv/appdata/jellyfin-cache
   ```
3. `kubectl apply -k apps/media/jellyfin`; log in at `http://nas:8096`.
4. Verify: Dashboard -> Libraries paths unchanged (`/srv/Media/Movies`, `/TV`,
   `/Anime`); item counts unchanged; a known watched item still watched; a TV
   client plays without reconfiguration; `http://jellyfin.lan` works
   (Dashboard -> Networking -> Known proxies: `10.42.0.0/16`). Enable
   Dashboard -> Advanced -> "Enable metrics" (Prometheus `/metrics`, Phase 7).
5. ### SUDO: `sudo systemctl disable jellyfin`.

Rollback: scale to 0; `sudo systemctl start jellyfin` (native dirs untouched).

---

## 8. Phase 4 - Indexers + Radarr/Sonarr rebuild (Prowlarr replaces Jackett)

1. FlareSolverr: `ghcr.io/flaresolverr/flaresolverr:<pinned>`, port 8191,
   env `LOG_LEVEL=info`, no volumes.
2. Prowlarr: `lscr.io/linuxserver/prowlarr:<pinned>`, `PUID=980 PGID=1003`,
   hostPath `/srv/appdata/prowlarr` -> `/config`, Ingress `prowlarr.lan`. UI:
   - Settings -> Indexers -> FlareSolverr `http://flaresolverr.media.svc.cluster.local:8191`, tag `flaresolverr`.
   - Indexers: 1337x (tag flaresolverr), EZTV, Nyaa.si, TorrentsCSV, The Pirate
     Bay, YTS, LimeTorrents, AniDex. Skip ehentai (unusable by arr).
     Document in `media-workflow.md`: public trackers are the weak link; a
     private tracker added here later improves everything.
   - Settings -> Apps: Radarr `http://radarr.media.svc.cluster.local:7878`,
     Sonarr `http://sonarr.media.svc.cluster.local:8989`, Prowlarr server
     `http://prowlarr.media.svc.cluster.local:9696`, Full Sync. API keys in
     `secrets/arr.env`.
3. Radarr: `lscr.io/linuxserver/radarr:<pinned>`, `PUID=973 PGID=1003 UMASK=002`,
   hostPath `/srv/appdata/radarr` -> `/config` (FRESH; old DB is empty),
   `/srv/Media` -> `/srv/Media`, Ingress `radarr.lan`. Configure:
   - Root folder `/srv/Media/Movies`. Rename Movies ON.
     Movie Folder Format: `{Movie CleanTitle} ({Release Year}) [tmdbid-{TmdbId}]`
     Standard Movie Format: `{Movie CleanTitle} ({Release Year}) {edition-{Edition Tags}} {[Custom Formats]}{[Quality Full]}{[MediaInfo 3D]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoCodec]}{-Release Group}`
     (Jellyfin recognises `[tmdbid-NNN]` in folder names.)
   - Use Hardlinks ON; Import Extra Files ON (`srt,nfo`); Minimum Free Space
     100 GB; Recycle Bin `/srv/Media/Torrents/.recycle` (same mount -> rename)
     cleanup 14 days; Set Permissions ON chmod 775/664 group `media`.
   - Download client qBittorrent: host `qbittorrent.media.svc.cluster.local`,
     port 8080, creds, category `radarr`, Remove Completed OFF.
     Remote Path Mapping: host `qbittorrent.media.svc.cluster.local`, remote
     `/srv/misc/torrents/`, local `/srv/Media/Torrents/`.
   - Connect -> Jellyfin: `http://jellyfin.media.svc.cluster.local:8096` +
     Jellyfin API key; update library on import/rename/upgrade.
   - Authentication: Forms, required for ALL addresses (fixes the API key leak).
   - Update mechanism: external (LinuxServer default).
4. Sonarr: `lscr.io/linuxserver/sonarr:<pinned>`, `PUID=972 PGID=1003 UMASK=002`,
   fresh `/srv/appdata/sonarr`, `/srv/Media`, Ingress `sonarr.lan`.
   - Root folders `/srv/Media/TV` and `/srv/Media/Anime`.
   - Series Folder Format `{Series TitleYear} [tvdbid-{TvdbId}]`; Season Folder
     `Season {season:00}`; Standard Episode Format
     `{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} {[Custom Formats]}{[Quality Full]}{[MediaInfo VideoDynamicRangeType]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[MediaInfo VideoCodec]}{-Release Group}`;
     Anime Episode Format same plus ` {absolute:000}` after the SxxEyy token.
   - Download clients: qBittorrent twice - "qBittorrent-TV" category
     `tv-sonarr`, and "qBittorrent-Anime" category `anime-sonarr` with client
     tag `anime` (series tagged `anime` route there). Same Remote Path Mapping
     and Jellyfin Connect as Radarr. Auth Forms required for all.
5. Recyclarr: `ghcr.io/recyclarr/recyclarr:<pinned>` as a CronJob (daily),
   hostPath `/srv/appdata/recyclarr` -> `/config`, `recyclarr.yml`:
   - Radarr profile "HD->UHD Upgrade": qualities WEBRip-1080p/WEBDL-1080p/
     Bluray-1080p up to Remux-2160p; `upgrade_allowed: true`,
     `until_quality: Remux-2160p`, `until_score: 10000`; TRaSH "HD Bluray + WEB"
     and "UHD Bluray + WEB" custom formats; positive scores for Remux tiers,
     HDR, DV (HDR fallback); do NOT penalise x265 (library is x265-heavy);
     negative for LQ/upscaled/BR-DISK.
   - Sonarr profile "HD->UHD Upgrade" (WEB-1080p -> Bluray-2160p Remux) and
     profile "Anime" with TRaSH anime custom formats (release-group tiers, Dual
     Audio high, uncensored preferred).
   - Document plainly: arr grabs the BEST-scoring release available at request
     time, then upgrades via RSS until cutoff. It does not deliberately grab a
     small file first. Disk-space priority is only Minimum Free Space + qbit
     queue limits + TRaSH per-quality size limits.
6. Unpackerr: `ghcr.io/unpackerr/unpackerr:<pinned>`, runAsUser 985 / fsGroup
   1003, env with Radarr/Sonarr URLs + keys, hostPath `/srv/Media`.
7. Bazarr: `lscr.io/linuxserver/bazarr:<pinned>`, `PUID=981 PGID=1003`,
   `/srv/appdata/bazarr`, `/srv/Media`, Ingress `bazarr.lan`; connect Radarr/
   Sonarr via cluster DNS; provider OpenSubtitles.com (creds in
   `secrets/bazarr.env`); language English.
8. Import existing libraries (no data movement):
   - Radarr -> Library Import -> `/srv/Media/Movies` -> select all -> profile
     "HD->UHD Upgrade", monitored. Expect ~212 matched; resolve unmatched
     manually in the dialog.
   - TV consolidation FIRST (### SUDO, renames only). Implementer produces the
     exact list from `ls /srv/Media/TV` for user review, e.g.
     `mkdir "/srv/Media/TV/Peaky Blinders (2013)"; mv "/srv/Media/TV/Peaky.Blinders.S01.1080p.BluRay.x265-RARBG" "/srv/Media/TV/Peaky Blinders (2013)/Season 01"` ...;
     merge `The Flash S01-S07/S08/S09` into `The Flash (2014)/`; `The Sopranos S01-S06...` -> `The Sopranos/`.
     Then Sonarr -> Library Import -> `/srv/Media/TV`.
   - Anime is NOT imported into Sonarr. Shoko owns the existing anime library
     (Phase 6). Sonarr uses `/srv/Media/Anime` only as root for NEW anime.
9. Rename everything (owner decision). First ### SUDO
   `sudo tar -czf /srv/Backups/migration-*/jellyfin-pre-rename.tgz -C /srv/appdata jellyfin`.
   Radarr: Movies -> Mass Editor -> select all -> Edit -> Root Folder
   `/srv/Media/Movies` -> "Yes, move the files" (applies folder format; same fs
   -> instant rename, hardlinks intact) -> then Rename Files. Same in Sonarr for
   TV. Jellyfin keys user data by provider IDs, so watched state normally
   survives; verify on 3 known watched items after the Connect-triggered scan.
   If lost: restore the tarball and rename back.
10. End-to-end test without Seerr: add a public-domain test movie in Radarr,
    Search -> grab -> qbit category `radarr` -> import via hardlink
    (`stat -c %h` of library file == 2) -> appears in Jellyfin. Remove after.
11. ### SUDO: `sudo systemctl disable --now radarr jackett` (sonarr already disabled).

Multi-season packs (`docs/media-workflow.md`): Sonarr rejects multi-season
packs by design. Workflow: add the magnet in qBittorrent with category
`manual`; when complete, Sonarr -> Wanted -> Manual Import ->
`/srv/Media/Torrents/completed/manual/<pack>` -> Sonarr parses each `SxxEyy`
file and hardlinks into the series folder. For anime batches use category
`anime-direct` (saves straight into `/srv/Media/Anime`); Shoko identifies by
hash. Single-season packs are handled automatically.

---

## 9. Phase 5 - Seerr (single request entry point)

1. `ghcr.io/seerr-team/seerr:<pinned>`, port 5055, `securityContext.runAsUser:
   982, fsGroup: 1003`, hostPath `/srv/appdata/seerr` -> `/app/config`,
   Ingress `seerr.lan`, probe `httpGet /api/v1/status`.
2. Wizard: Jellyfin at `http://jellyfin.media.svc.cluster.local:8096`,
   external URL `http://jellyfin.lan`; import Jellyfin users; sync libraries
   Movies, TV, Anime.
3. Services -> Radarr default: `radarr.media.svc.cluster.local:7878`, profile
   "HD->UHD Upgrade", root `/srv/Media/Movies`, min availability Released, tag
   `seerr`. Sonarr default: `sonarr...:8989`, profile "HD->UHD Upgrade", root
   `/srv/Media/TV`; Anime settings: profile "Anime", root `/srv/Media/Anime`,
   series type Anime, tag `anime`, season folders ON. Enable library scan so
   requests flip to Available.
4. Auto-approve for the owner's user. Verify: request movie -> Radarr -> qbit
   -> Jellyfin -> Seerr "Available".

---

## 10. Phase 6 - Shoko Server + Shokofin (anime metadata)

1. Shoko Server image `ghcr.io/shokoanime/server:<pinned>` - pick a version in
   the Shokofin compatibility matrix for Jellyfin 10.11 (Shokofin 6.0.x <->
   Shoko 5.2.x-5.3.x at time of writing; re-check the README). `PUID=983
   PGID=1003`, port 8111, hostPath `/srv/appdata/shoko` -> `/home/shoko/.shoko`,
   hostPath `/srv/Media` -> `/srv/Media` READ-ONLY (Shoko must never
   move/rename), Ingress `shoko.lan`, memory limit 4Gi.
2. First run: AniDB account (owner creates; creds in `secrets/shoko.env`), SQLite.
   Import Folder `/srv/Media/Anime`, type Source, Drop Destination OFF, watch
   ON. Settings -> Import: disable rename/move. TMDB auto-link ON. Start scan:
   reads 1.6 TB once (hours) + AniDB UDP lookups (rate-limited; 1-2 days).
   Copies nothing.
3. Jellyfin: add plugin repo
   `https://raw.githubusercontent.com/ShokoAnime/Shokofin/metadata/stable/manifest.json`,
   install "Shoko", `kubectl -n media rollout restart deploy/jellyfin`.
   Shokofin settings: host `http://shoko.media.svc.cluster.local:8111`, creds,
   VFS ENABLED. Recreate the Jellyfin "Anime" library as Shows with only Shoko
   providers, path `/srv/Media/Anime`. Old Anime library watch state is lost
   (accepted by owner).
4. Verify: Kimetsu no Yaiba, Hunter x Hunter (2011), Overlord seasons show
   correct titles/episodes/art; a new Sonarr-imported anime appears via Shoko's
   watcher.

---

## 11. Phase 7 - Observability (kube-prometheus-stack)

Why this and not hand-assembled prometheus+grafana charts: upstream-maintained
dashboards and alert rules, one uniform `ServiceMonitor` per new target,
Grafana datasource pre-wired, sidecar dashboard loading built in. Cost: an
operator, ~10 CRDs, ~1 GiB RAM - irrelevant on 31 GiB. The Grafana "sidecar
ConfigMap" mechanism is a standard feature of the Grafana Helm chart (watches
ConfigMaps labelled `grafana_dashboard: "1"`), not a custom invention.

1. Umbrella chart `apps/observability/kube-prometheus-stack/`:
   - `Chart.yaml`: `apiVersion: v2`, `name: observability`, `version: 0.1.0`,
     `dependencies: [{name: kube-prometheus-stack, version: "<pinned>", repository: https://prometheus-community.github.io/helm-charts}]`
   - `values.yaml` (everything under the `kube-prometheus-stack:` key):
     - `kubeControllerManager.enabled: false`, `kubeScheduler.enabled: false`,
       `kubeEtcd.enabled: false`, `kubeProxy.enabled: false` (k3s does not
       expose these; otherwise permanent TargetDown alerts)
     - `prometheus.prometheusSpec`: `retention: 30d`, `retentionSize: 40GB`,
       `serviceMonitorSelectorNilUsesHelmValues: false`,
       `podMonitorSelectorNilUsesHelmValues: false`,
       `ruleSelectorNilUsesHelmValues: false` (pick up ALL monitors/rules,
       not only the chart's own - the most common footgun), storage via
       `volumes`/`volumeMounts` hostPath `/srv/appdata/prometheus` (disposable)
     - `grafana`: admin creds from Secret, persistence hostPath
       `/srv/appdata/grafana`, `sidecar.dashboards.enabled: true`,
       `sidecar.dashboards.searchNamespace: ALL`, ingress `grafana.lan`
     - `alertmanager`: enabled, storage hostPath `/srv/appdata/alertmanager`,
       config with a single `null` receiver; route `Watchdog` and
       `InfoInhibitor` to null. Phone + email receivers DEFERRED (owner
       decision) - adding them later is a values-only change.
     - `prometheus-node-exporter`: extra collectors `mdadm hwmon thermal_zone`
     - ingress `prometheus.lan`, `alertmanager.lan`
   - Apply: `helm dependency update apps/observability/kube-prometheus-stack && helm upgrade --install observability apps/observability/kube-prometheus-stack -n observability -f apps/observability/kube-prometheus-stack/values.yaml`
     (Makefile target `apply-observability`). Chart major upgrades require
     applying the new CRDs first (`kubectl apply --server-side -f <crds>`);
     the chart's upgrade notes say when.
2. Exporters in `apps/observability/exporters/`, each Deployment/DaemonSet +
   Service + ServiceMonitor:
   - smartctl-exporter (`quay.io/prometheuscommunity/smartctl-exporter:<pinned>`),
     privileged, hostPath `/dev`, devices sda-sde. RAID member health is the
     most important metric on this box.
   - exportarr (`ghcr.io/onedr0p/exportarr:<pinned>`) x4: radarr, sonarr,
     prowlarr, bazarr (API keys from secrets).
   - qbittorrent-exporter (`ghcr.io/martabal/qbittorrent-exporter:<pinned>`).
   - Jellyfin: ServiceMonitor on the existing `jellyfin` Service, path `/metrics`.
   - Traefik: k3s `HelmChartConfig` for traefik enabling `metrics.prometheus`
     and its `serviceMonitor`.
3. Dashboards `apps/observability/dashboards/`: one ConfigMap per JSON
   (Node Exporter Full 1860, smartctl-exporter dashboard, Exportarr Radarr/
   Sonarr/Prowlarr, qbittorrent-exporter, Jellyfin, Traefik), labelled
   `grafana_dashboard: "1"`. Kubernetes dashboards come with the chart.
4. `apps/observability/rules/prometheusrule.yaml`:
   `node_md_disks{state="failed"} > 0`;
   `node_filesystem_avail_bytes{mountpoint="/srv"} < 500e9`;
   `smartctl_device_smart_status != 1`;
   `up{job=~"radarr|sonarr|prowlarr|qbittorrent|jellyfin|seerr"} == 0 for 10m`.
   Pod restart/OOM alerts exist upstream.
5. Deferred: SNMP exporter (OPNsense), Loki + Alloy.

Verify: `kubectl -n observability get servicemonitors` lists every app;
Prometheus -> Status -> Targets all UP; Grafana shows upstream + imported
dashboards; scaling radarr to 0 for 10 min fires the alert in Alertmanager UI.

---

## 12. Phase 8 - Backups, updates, hardening, operations

### 12.1 Backups (extend existing rclone job; no restic)
1. ### SUDO systemd drop-in for `rclone-backup.service` (keep both existing
   `ExecStart` lines untouched):
   ```ini
   [Service]
   ExecStartPre=/srv/appdata/_scripts/snapshot-sqlite.sh
   ExecStart=/usr/bin/rclone sync /srv/appdata Backblaze:John-System-Backups/appdata --exclude 'prometheus/**' --exclude 'jellyfin-cache/**' --exclude '*/logs/**' --exclude '*.db-wal' --exclude '*.db-shm'
   ```
   Versioning of overwritten/deleted files is provided by the B2 bucket's
   existing lifecycle rules (no `--backup-dir`).
2. `scripts/snapshot-sqlite.sh` (deployed to `/srv/appdata/_scripts/`): for
   each live SQLite DB - jellyfin `data/jellyfin.db` and `data/library.db`,
   seerr `db/db.sqlite3`, bazarr `db/bazarr.db`, shoko DB, grafana
   `grafana.db`, home-assistant `home-assistant_v2.db` - run
   `sqlite3 "$db" ".backup /srv/appdata/_snapshots/<app>/<name>.db"`
   (SQLite online backup API = consistent copy while running). Radarr/Sonarr/
   Prowlarr already write weekly zips to `<app>/Backups/`; qBittorrent
   `BT_backup` is many small files, fine to copy live; Matter `*.json` +
   `.backup` are tiny and included. Excluded `prometheus/` is disposable by
   decision; `jellyfin-cache` regenerates.
3. `docs/disaster-recovery.md`: reinstall Arch/k3s -> mount `/srv` ->
   `git clone` -> `rclone copy Backblaze:John-System-Backups/appdata /srv/appdata`
   -> if a live DB is corrupt replace with `_snapshots/<app>/<name>.db` ->
   `make apply-all`. Rehearse once with Prowlarr before closing Phase 8.

### 12.2 k3s vs Arch packages (documented in operations.md)
- `get.k3s.io` installs ONE statically linked binary at `/usr/local/bin/k3s`
  embedding containerd, runc, kubelet, kube-proxy, CoreDNS, Flannel, and its
  own iptables/nftables userspace. `/usr/local` is outside pacman; `pacman -Syu`
  cannot desync k3s from itself. Arch `containerd/runc/iptables` are Docker
  deps only and leave with Docker in Phase 9.
- Kernel upgrades: no effect until reboot; required modules (`overlay`,
  `br_netfilter`, `vxlan`, conntrack/nat) are in-tree. After reboot k3s waits
  for `/srv` (drop-in from Phase 1) then all pods return (state is hostPath).
- NEVER install `k3s`/`k3s-bin` from the AUR (would tie a Kubernetes minor jump
  to `yay -Syu`; minors must not be skipped). Do not install Arch `kubectl`;
  use `k3s kubectl`. Arch `helm` is fine (client only).
- k3s upgrade = edit `K3S_VERSION` in `bootstrap/k3s/install.sh`, commit,
  `sudo bash bootstrap/k3s/install.sh` (restarts k3s; running pods survive;
  API gone ~20 s). One Kubernetes minor at a time; read release notes.
  Rollback = set old version, rerun. `system-upgrade-controller` is out of scope.

### 12.3 Application updates (Dependabot)
- All image tags pinned; no `latest`/`stable`. HA and matter-server get pinned
  versions in Phase 9 so Dependabot can track them.
- `.github/dependabot.yml`:
  ```yaml
  version: 2
  updates:
    - package-ecosystem: docker
      directories: ["/apps/**"]
      schedule: { interval: weekly, day: sunday }
      groups:
        linuxserver: { patterns: ["lscr.io/linuxserver/*"] }
        exporters:   { patterns: ["*exporter*", "ghcr.io/onedr0p/exportarr"] }
        home:        { patterns: ["ghcr.io/home-assistant/*", "ghcr.io/matter-js/*"] }
      ignore:
        - dependency-name: "jellyfin/jellyfin"
          update-types: ["version-update:semver-major", "version-update:semver-minor"]
    - package-ecosystem: helm
      directory: "/apps/observability/kube-prometheus-stack"
      schedule: { interval: weekly, day: sunday }
  ```
  Dependabot's `docker` ecosystem parses Kubernetes manifests for image tags;
  its `helm` ecosystem bumps `Chart.yaml` dependency versions (this is why the
  umbrella chart exists instead of kustomize `helmCharts:`, which Dependabot
  does not read).
- Verify on the first Sunday run that PRs appear for a LinuxServer image
  (tags like `6.2.1.10461-ls283`). If the tag shape is not parsed, switch to
  LSIO's `version-X.Y.Z` tags.
- Limitations accepted: cannot bump `K3S_VERSION` in a shell script (manual,
  deliberate); cannot enforce "matter-server <= what HA requires" (grouped PR +
  read HA release notes); Jellyfin plugins (Shokofin) update inside Jellyfin's
  plugin UI.
- Workflow: merge PR -> `kubectl apply -k apps/<ns>/<app>` (Recreate restarts
  pod) or `make apply-observability` for the chart. Rollback = `git revert` +
  apply.
- Per-app cautions: Jellyfin minors run one-way DB migrations - snapshot +
  `tar` `/srv/appdata/jellyfin` first and confirm Shokofin compatibility;
  Home Assistant monthly releases break integrations - read breaking changes,
  rely on HA's built-in scheduled backups (`/config/backups`, in the rclone
  set); matter-server only in the same PR as HA when HA requires it;
  kube-prometheus-stack majors need CRDs applied first; qBittorrent/arr never
  downgrade.
- Cadence: stateless/low-risk PRs anytime; stateful ones (Jellyfin, HA, Shoko,
  kube-prometheus-stack) batched into a monthly window right after
  `pacman -Syu` + reboot so one reboot validates kernel + k3s + apps together.

### 12.4 Hardening & ops
- `chmod 750 /srv/Backups` etc. (Phase 0 step 4). All web UIs require login.
  Jackett (`AllowExternal`) retired.
- `scripts/status.sh`, `scripts/restart.sh <ns> <deploy>`, `scripts/logs.sh`,
  Makefile targets; complete `docs/operations.md` including the 11:30 PM
  runbook and "when self-healing gets in the way: `kubectl scale --replicas=0`".

---

## 13. Phase 9 - Home Assistant, then Matter Server (last, most risky)

Docker keeps running until both are verified. Order: 9.0 host networking ->
9a HA -> 9b Matter (a later day) -> Docker removal.

### 13.0 Diagnosed failure: Matter nodes "unavailable" after reboot (2026-09-30)
Evidence (boot 2026-09-30 08:50 local):
- `dhcpcd.service` runs `dhcpcd -q -B` and nothing implements
  `network-online.target`, so "Network is Online" was reached at :06.2 -
  before the NIC even had carrier (:09.1). The initramfs `netconf` cleanup
  hook flushes and downs `eth0` before switch_root, so the real root always
  starts link-down (~3 s renegotiation), widening the race.
- Docker (`Wants/After=network-online.target`) started matter-server at
  :09.5. Its init saw no DNS (`Temporary failure in name resolution`) and no
  usable addresses (`Cannot assign requested address`); IPv6 global + default
  route arrived at :11.4, IPv4 lease at :14.8. k3s crashed on the same race
  (`no default routes found`) and was restarted by systemd.
- The CHIP stack binds its mDNS/operational-discovery sockets once at start
  and never re-enumerates: 3 h later `get_nodes` returned 12 nodes,
  0 available. Port 5580 listening and HA connected with no errors, so a
  `tcpSocket` probe would never detect it. `docker restart matter-server`
  fixes it (12/12 available).

Fix (layered):
1. Root cause (9.0): make `network-online.target` real with
   systemd-networkd + `systemd-networkd-wait-online` (both families routable).
   Evaluated: dhcpcd@enp5s0 (`-w`, `waitip`) - single-interface mode exits at
   timeout and `waitip 6` semantics vs link-local are undocumented;
   NetworkManager - new package, desktop-oriented, needs CNI-interface
   ignores. networkd ships with systemd and has explicit per-family
   wait-online.
2. Runtime blips: init container waits for host IPv4 default route + global
   IPv6 before matter-server / HA start (hostNetwork sees host interfaces).
3. Self-heal: semantic probe `apps/home/matter-server/health.py` (WebSocket
   `get_nodes`; fail iff nodes > 0 and available == 0) as startupProbe
   (5 min budget) and livenessProbe (5 min of zero reachable nodes).
4. Visibility: PrometheusRule on matter-server restarts (> 2 in 1 h).

### 13.0.1 Phase 9.0 - host networking: dhcpcd -> systemd-networkd + resolved
Initramfs constraint (tinyssh remote LUKS unlock) - NEVER change in this
phase: mkinitcpio `HOOKS` (`netconf tinyssh encryptssh`), the kernel
`ip=:::::eth0:dhcp` parameter, no `.link` files, no mkinitcpio rebuild. The
initramfs uses busybox + klibc `ipconfig`, independent of any real-root DHCP
client.

Files (`bootstrap/host/network/`):
- `10-lan.network` -> `/etc/systemd/network/`: match MAC
  `d4:5d:64:ba:44:dd`; `RequiredForOnline=routable`,
  `RequiredFamilyForOnline=both`; `IPv6AcceptRA=yes` explicit (k3s enables
  IPv6 forwarding); `UseDomains=yes`; `KeepConfiguration=dynamic-on-stop`;
  dhcpcd's DHCP identity preserved (`DUIDType=link-layer-time`,
  `DUIDRawData=00:01:2c:56:10:20:d4:5d:64:ba:44:dd`, `IAID=0x64ba44dd`) so
  OPNsense keeps handing out 10.0.0.4 and `::2000`; `UseHostname=no`;
  `Token=prefixstable` (RFC 7217, like `slaac private`).
- `networkd-foreign.conf` -> `/etc/systemd/networkd.conf.d/10-foreign.conf`:
  `ManageForeignRoutes=no`, `ManageForeignRoutingPolicyRules=no` (k3s/Docker).
- `resolved-lan.conf` -> `/etc/systemd/resolved.conf.d/10-lan.conf`:
  `MulticastDNS=no`, `LLMNR=no` (Matter/HA own 5353).
- `networkd-revert.{sh,service,timer}`: safety net. Timer
  `OnStartupSec=20min` (counts from systemd start = after the LUKS unlock),
  enabled for the next boot only; reverts to dhcpcd and reboots unless
  cancelled.
- `verify-networkd.sh`: read-only post-reboot checks (no sudo).
- `bootstrap/host/phase9-0-networkd.sh` (SUDO): precondition checks
  (MAC, cmdline, HOOKS, DUID file, resolv.conf) -> install -> mask
  `systemd-network-generator.service` (it would translate the
  initramfs-only `ip=` into a second networkd config) -> enable
  networkd/wait-online/resolved -> disable dhcpcd -> enable revert timer ->
  `/etc/resolv.conf` -> `../run/systemd/resolve/stub-resolv.conf`
  (original kept as `/etc/resolv.conf.dhcpcd`). Does not reboot itself.

Steps: ### SUDO `sudo bash bootstrap/host/phase9-0-networkd.sh`; ### SUDO
`sudo systemctl reboot`; unlock via tinyssh as usual; SSH in; ### SUDO
`sudo systemctl disable --now networkd-revert.timer`; run
`bash bootstrap/host/network/verify-networkd.sh` (all PASS).
Rollback: `sudo /usr/local/sbin/networkd-revert.sh` (reverts + reboots;
`--no-reboot` to skip). dhcpcd stays installed.

### 13.1 Home Assistant (9a)
1. `apps/home/home-assistant/deployment.yaml`:
   `ghcr.io/home-assistant/home-assistant:2025.12.4` (= `.HA_VERSION` from
   capture), `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`,
   `replicas: 1`, `Recreate`, hostPath `/srv/appdata/home-assistant` ->
   `/config`, hostPath `/etc/localtime` ro, `privileged: false`, env `TZ`;
   init container (pinned busybox) waiting for host IPv4 default route +
   global IPv6 on `enp5s0`; probe `httpGet / 8123` with
   `initialDelaySeconds: 60`. Ingress `ha.lan` (owner-confirmed 2026-09-30;
   selectorless Service + static EndpointSlice to 10.0.0.4:8123 - keeps
   working during a Docker rollback - v1 Endpoints API is deprecated in
   k8s >= 1.33). Requires `http: use_x_forwarded_for: true,
   trusted_proxies: [10.42.0.0/16]` in `configuration.yaml` - appended to
   the migrated copy by `phase9a-migrate-ha.sh` (without it HA answers
   `400 Bad Request` because Traefik sends X-Forwarded-For untrusted;
   verified empirically pre-migration).
2. ### SUDO: `cd /srv/homeassistant && docker compose stop homeassistant`;
   `rsync -aHAX /srv/homeassistant/config/ /srv/appdata/home-assistant/`;
   `make apply-home`.
3. Verify: `http://nas:8123` login; all integrations loaded (compare domain
   list from capture); Matter integration still connected to
   `ws://localhost:5580/ws` (matter-server still in Docker, host network);
   automations fire; mDNS/SSDP discovery lists devices; mobile app reconnects.
4. Rollback: `kubectl -n home scale deploy/home-assistant --replicas=0 && docker compose start homeassistant`.
   Leave the Docker container defined (stopped) for a week.

### 13.2 Matter Server (9b)
1. `apps/home/matter-server/deployment.yaml`:
   `ghcr.io/matter-js/python-matter-server:8.1.2` (running version; confirm the
   tag's digest equals the running `sha256:6827e352...aad3` before use; 8.1.2
   is the final release - project archived),
   `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`, args
   `--storage-path /data --paa-root-cert-dir /data/credentials`, hostPath
   `/srv/appdata/matter-server` -> `/data`, hostPath `/run/dbus` -> `/run/dbus`
   ro, `privileged: false` (AppArmor is not active on Arch; the compose
   `apparmor:unconfined` needs no equivalent). Same network-wait init
   container as HA. `health.py` mounted from a ConfigMap at `/probe`:
   startupProbe exec `python3 /probe/health.py` period 10 s,
   failureThreshold 30; livenessProbe same command period 60 s, timeout 10 s,
   failureThreshold 5. Known trade-off: if every device is genuinely offline
   the pod restarts with backoff (max 5 min) - harmless, restart is the
   recovery action. PrometheusRule `MatterServerRestarting`:
   `increase(kube_pod_container_status_restarts_total{namespace="home",container="matter-server"}[1h]) > 2`.
2. ### SUDO: `docker compose stop matter-server`;
   `rsync -aHAX /home/john/docker/matter-server/data/ /srv/appdata/matter-server/`
   (1.5 MB; the fabric - also copy to `/srv/Backups/migration-*/`); apply.
3. Verify: HA Matter integration reconnects; every Matter device controllable;
   commission one device if possible; `kubectl -n home exec deploy/matter-server
   -- python3 /probe/health.py` shows all nodes; full reboot test (no manual
   action, nodes available < 5 min); `kubectl delete pod` recovers; pull the
   host ethernet ~30 s and confirm devices return. If flaky for > 1 week,
   roll back to Docker (ChatGPT session guidance: move Matter out rather than
   fight IPv6/mDNS in Kubernetes).
4. After 2 weeks stable ### SUDO: `docker compose down` in `/srv/homeassistant`;
   `systemctl disable --now docker docker.socket`; archive
   `/home/qbittorrent /var/lib/{radarr,sonarr,jackett,jellyfin} /etc/jellyfin /srv/homeassistant /home/john/docker`
   into `/srv/Backups/migration-*/legacy-state.tgz`; optionally
   `pacman -Rns docker docker-compose jackett radarr sonarr-bin qbittorrent-nox jellyfin-server jellyfin-web jellyfin-ffmpeg`.
   Keep `dhcpcd` installed (9.0 rollback path).

### 13.3 Deferred - Phase 10: matterjs-server
python-matter-server is archived (8.1.2 final); `matterjs-server` is the
upstream drop-in replacement used by HA 2026.x. One-way data migration:
back up the fabric first, pair with the HA upgrade that requires it, rewrite
`health.py` for the Node-based image (WebSocket `get_nodes` API unchanged).
Not combined with the k3s move.

---

## 14. Data-handling summary

| Data | Size | Action | Mechanism |
|---|---|---|---|
| `/srv/Media/{Movies,TV,Anime}` | 9 TB | untouched; folder/file renames by arr; group/mode normalization | `rename()` on same fs; metadata-only chgrp/chmod |
| `/srv/misc/torrents` -> `/srv/Media/Torrents` | 7 TB | move | one `mv` (rename) + host symlink |
| Hardlinks torrents<->library | - | preserved | rename never changes inodes |
| qBittorrent state | MBs | copy to `/srv/appdata/qbittorrent` | rsync; stored paths kept valid by compat mount A |
| Jellyfin data/config/cache | GBs | copy to `/srv/appdata/jellyfin{,-cache}` | rsync; same version pinned |
| Radarr/Sonarr DB | empty | discard; rebuild via Library Import | - |
| Jackett | - | retire; indexers re-added in Prowlarr | - |
| HA config, Matter fabric | 11 MB, 1.5 MB | copy to `/srv/appdata` | rsync + extra backup copy |
| Prometheus TSDB | new | disposable | not backed up |
| k3s runtime `/var/lib/rancher/k3s` | GBs | on SSD; disposable | reinstall recreates |

---

## 15. Items the owner supplies during implementation
- qBittorrent WebUI credentials, BT listen port `P`, torrent count `N` (from
  capture / WebUI footer) - before Phase 2.
- AniDB account (Phase 6), OpenSubtitles.com account (Phase 4), Jellyfin API
  key (Phases 4-5).
- Alertmanager receivers (phone + email) - DEFERRED until functionally stable.
- Confirmation that the `Porn` library/category/share is carried over unchanged
  (assumed yes).
- Running every `### SUDO (user runs)` block and confirming completion.

## 16. Phase order and gating
0 prep -> 1 k3s -> 2 qBittorrent (+torrent move) -> 3 Jellyfin -> 4 Prowlarr/
Radarr/Sonarr/Recyclarr/Bazarr/Unpackerr -> 5 Seerr -> 6 Shoko -> 7 observability
-> 8 backups/updates/ops -> 9.0 host networking (networkd) -> 9a Home
Assistant -> 9b Matter Server -> Docker removal -> (10 matterjs-server). Each phase's verification checklist must pass and be committed before
the next begins. Phases 7 and 8 may run in parallel with 5-6 if desired; 9 is
always last.
