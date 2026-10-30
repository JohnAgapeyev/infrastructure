# Architecture

Single-node k3s cluster on host `nas` (Arch Linux, 8 cores, 31 GiB RAM, LUKS
RAID6 ext4 `/srv`). Source of decisions: [PLAN.md](PLAN.md).

## Layout

- **k3s** (installed via `get.k3s.io`, pinned version, NOT the AUR package)
  single node `nas`, sqlite datastore, bundled Traefik + klipper servicelb +
  CoreDNS + metrics-server. Runtime state `/var/lib/rancher/k3s` (SSD,
  disposable).
- **Namespaces**: `media`, `home`, `observability`, `cloud`, `ai` (see
  `cluster/`).
- **App state**: `/srv/appdata/<app>` on the RAID array, mounted via plain
  `hostPath` volumes (type Directory). No PV/PVC, no operators beyond
  kube-prometheus-stack.
- **Media**: one hostPath `/srv/Media` -> `/srv/Media` in every pod that
  touches media (hardlinks require torrent dir and library dir on the same
  mount). qBittorrent additionally mounts `/srv/Media/Torrents` at
  `/srv/misc/torrents` for fastresume path compatibility.
- **Ingress**: bundled Traefik, TLS via a Let's Encrypt wildcard for
  `*.home.jg-a.com` (cert-manager DNS-01 against Cloudflare) installed as
  Traefik's default certificate; hostnames `<slug>.home.jg-a.com` resolved
  via OPNsense Unbound wildcard host override `*` -> 10.0.0.4. Split DNS,
  renewal and ops detail: [tls.md](tls.md). Legacy host ports 8096
  (Jellyfin) and 8080 (qBittorrent WebUI) are kept via LoadBalancer services
  (klipper); the qBittorrent BT port is a pod `hostPort`.
- **Users/permissions**: pods run as the same UIDs as the legacy systemd
  services (see [storage-layout.md](storage-layout.md)); GID 1003 `media`
  everywhere; `UMASK=002`; `replicas: 1` + `strategy: Recreate` for every
  stateful app.
- **Secrets**: gitignored `secrets/*.env` consumed by kustomize
  `secretGenerator`; committed `*.env.example` files document the keys.
- **Network policy**: default-deny (ingress+egress) with explicit allows
  in `cluster/network-policies/media.yaml` (inter-service, DNS, LAN,
  traefik/observability namespaces, per-app internet egress; BT port
  41045 open for torrent peers). home ns is hostNetwork - policies never
  apply there. home ns is hostNetwork - policies never
  apply there. The cloud ns (NC phase) is default-deny too: DNS +
  same-ns (postgres/redis), internet + SMTP egress for the nextcloud pod
  only, ingress from traefik/observability - no LAN allow needed (all
  clients go through Traefik). The ai ns (H2 phase) is default-deny:
  DNS + same-ns (hermes -> openviking), internet 443 (OpenRouter/npm -
  hermes, openviking, joplin-export, and the disabled openclaw/letta
  pods stay in the allow list for revert), Nextcloud WebDAV for the
  joplin-export job only via the node IP (Traefik - so cloud needs no
  edit), ingress from traefik + observability; no ai pod mounts or
  reads `/srv/appdata/nextcloud-data` (the owner's Joplin notes are
  reached only through the official Joplin CLI over WebDAV, then
  upserted into OpenViking by the joplin-export job). The LC phase
  (2026-10-26) added librechat (web UI + its no-auth mongo) with NO new
  netpol allows: its egress is DNS + same-ns only (librechat ->
  hermes:8642 + -> librechat-mongo:27017 both ride the generic
  same-ns egress), deliberately excluded from the internet-443 allow -
  all model traffic goes in-cluster to hermes. The MX phase (2026-10-28)
  added tuwunel (Matrix homeserver, federation OFF) + element-web
  (static client) with NO new allows either: hermes -> tuwunel:8008
  rides the generic same-ns egress, both new pods are deliberately
  absent from the internet-443 list (the homeserver dials nothing
  with federation off; Element Web serves static files), so a
  compromised homeserver reaches nothing outside the ns.

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
| nextcloud (+ postgres, redis) | family cloud: files, photos (memories), calendar/contacts (NC phase) | `nextcloud:35.0.2-apache`, `postgres:18.6`, `redis:8.10.2-alpine` in `apps/cloud/` |
| openviking | context database = Hermes's memory/knowledge store (AI phase; **H2 phase: re-enabled**) | `ghcr.io/volcengine/openviking:v0.5.0` in `apps/ai/openviking` |
| hermes | AI agent gateway + web dashboard + OpenAI-compatible API server :8642 for Conduit (AI phase; **H2 phase: re-enabled**, D8 amended) | `nousresearch/hermes-agent:v0.22.2` in `apps/ai/hermes` |
| openclaw | AI agent gateway + Control UI + builtin memory (OC phase; **H2 phase: disabled** - replicas 0, kept for revert) | `ghcr.io/openclaw/openclaw:2026.10.5` in `apps/ai/openclaw` |
| letta | Letta App Server: stateful agents + Agent SDK remote backend (LET phase; **H2 phase: disabled** - replicas 0, kept for revert) | `ghcr.io/letta-ai/letta-code:0.34.19` in `apps/ai/letta` |
| librechat | web front-end for the Hermes agent gateway, via its OpenAI-compatible API :8642 over the in-cluster Service (LC phase) + no-auth mongo behind the default-deny | `ghcr.io/librechat-ai/librechat:v0.8.8` + `mongo:8.0.20` in `apps/ai/librechat` |
| tuwunel | Matrix homeserver for the Hermes gateway bot (`@hermes`) + family accounts; federation OFF, LAN/VPN-only (MX phase); E2EE OFF by decision (EE-off phase, 2026-10-29) | `jevolk/tuwunel:v1.9.4` in `apps/ai/tuwunel` |
| element-web | Element Web static client for the homeserver (MX phase) | `vectorim/element-web:v1.12.33` in `apps/ai/element-web` |
| joplin-export | official Joplin CLI sync client -> clean md export tree -> OpenViking upsert (CronJob, */5; ov leg restored in H2) | `node:24.22.0-bookworm-slim` + `joplin@3.7.1` + `@openviking/cli@0.4.23` in `apps/ai/joplin-export` |
| kube-prometheus-stack | metrics/alerts/dashboards | umbrella chart in `apps/observability/` |
| cert-manager | TLS issuance (LE wildcard via Cloudflare DNS-01) | `v1.21.2` pinned, `scripts/install-cert-manager.sh` |

Samba stays on the host (shares point into `/srv/Media`), as does the
rclone -> Backblaze B2 backup pipeline (extended to cover `/srv/appdata`).

## Update policy

All image tags pinned; no `:latest`/`:stable`. Updates arrive as GitHub
Dependabot PRs (docker + helm ecosystems) -> merge -> `kubectl apply -k` /
`make apply-observability`. k3s upgrades by editing `K3S_VERSION` in
`bootstrap/k3s/install.sh` and re-running it. Details: [operations.md](operations.md).
