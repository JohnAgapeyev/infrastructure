# Architecture

Single-node k3s cluster on host `nas` (Arch Linux, 8 cores, 31 GiB RAM, LUKS
RAID6 ext4 `/srv`). Source of decisions: [PLAN.md](PLAN.md).

## Layout

- **k3s** (installed via `get.k3s.io`, pinned version, NOT the AUR package)
  single node `nas`, sqlite datastore, bundled Traefik + klipper servicelb +
  CoreDNS + metrics-server. Runtime state `/var/lib/rancher/k3s` (SSD,
  disposable).
- **Namespaces**: `media`, `home`, `observability` (see `cluster/`).
- **App state**: `/srv/appdata/<app>` on the RAID array, mounted via plain
  `hostPath` volumes (type Directory). No PV/PVC, no operators beyond
  kube-prometheus-stack.
- **Media**: one hostPath `/srv/Media` -> `/srv/Media` in every pod that
  touches media (hardlinks require torrent dir and library dir on the same
  mount). qBittorrent additionally mounts `/srv/Media/Torrents` at
  `/srv/misc/torrents` for fastresume path compatibility.
- **Ingress**: bundled Traefik, plain HTTP, hostnames `<svc>.lan` resolved via
  OPNsense Unbound host overrides -> 10.0.0.4. Legacy host ports 8096
  (Jellyfin) and 8080 (qBittorrent WebUI) are kept via LoadBalancer services
  (klipper); the qBittorrent BT port is a pod `hostPort`.
- **Users/permissions**: pods run as the same UIDs as the legacy systemd
  services (see [storage-layout.md](storage-layout.md)); GID 1003 `media`
  everywhere; `UMASK=002`; `replicas: 1` + `strategy: Recreate` for every
  stateful app.
- **Secrets**: gitignored `secrets/*.env` consumed by kustomize
  `secretGenerator`; committed `*.env.example` files document the keys.

## Services

| Service | Purpose | Image |
|---|---|---|
| qbittorrent | torrents | `lscr.io/linuxserver/qbittorrent` |
| jellyfin | media server | `jellyfin/jellyfin` |
| prowlarr (+ flaresolverr) | indexer management | `lscr.io/linuxserver/prowlarr` / `ghcr.io/flaresolverr/flaresolverr` |
| radarr / sonarr | movie/TV automation | `lscr.io/linuxserver/{radarr,sonarr}` |
| recyclarr | TRaSH profile sync (CronJob) | `ghcr.io/recyclarr/recyclarr` |
| unpackerr | archive extraction | `ghcr.io/unpackerr/unpackerr` |
| bazarr | subtitles | `lscr.io/linuxserver/bazarr` |
| seerr | request front-end | `ghcr.io/seerr-team/seerr` |
| shoko (+ shokofin plugin) | anime metadata (AniDB) | `ghcr.io/shokoanime/server` |
| home-assistant / matter-server | smarthome (Phase 9) | `ghcr.io/home-assistant/*`, `ghcr.io/matter-js/*` |
| kube-prometheus-stack | metrics/alerts/dashboards | umbrella chart in `apps/observability/` |

Samba stays on the host (shares point into `/srv/Media`), as does the
rclone -> Backblaze B2 backup pipeline (extended to cover `/srv/appdata`).

## Update policy

All image tags pinned; no `:latest`/`:stable`. Updates arrive as GitHub
Dependabot PRs (docker + helm ecosystems) -> merge -> `kubectl apply -k` /
`make apply-observability`. k3s upgrades by editing `K3S_VERSION` in
`bootstrap/k3s/install.sh` and re-running it. Details: [operations.md](operations.md).
