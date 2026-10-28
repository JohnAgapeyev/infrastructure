# Operations runbook

Host: `nas` (10.0.0.4). Cluster: single-node k3s, node name `nas`.
Plan reference: [PLAN.md](PLAN.md).

## Daily driver commands

```bash
kubectl get pods -A                 # everything running?
make status                         # pods + svc + events + /srv usage
./scripts/logs.sh <ns> <deploy>     # e.g. ./scripts/logs.sh media qbittorrent
./scripts/restart.sh <ns> <deploy>  # rollout restart + wait
kubectl -n <ns> logs deploy/<x> --tail=200
kubectl -n <ns> rollout restart deploy/<x>
kubectl -n <ns> scale deploy/<x> --replicas=0   # stop an app
journalctl -u k3s -e                # k3s itself
journalctl -u rclone-backup.service -e           # backup job (incl. snapshots)
```

Applying changes: `make apply-media` / `apply-home` / `apply-cloud` /
`apply-ai` / `apply-observability` / `apply-all`, or
`kubectl apply -k apps/<ns>/<app>` (kubeconfig:
~/.kube/config; plain `kubectl apply -k` works for apps without
repo-root secrets; media/observability need the load restrictor - the
Makefile handles that).

## The 11:30 PM rule

If a pod is crash-looping at bedtime and the fix is not obvious: stop
poking it, `kubectl -n <ns> scale deploy/<x> --replicas=0`, and pick it up
tomorrow with a fresh mind. Self-healing restart loops hide root causes;
scaling to 0 quiets the noise and the logs stay available.

## Reboot behaviour

`/srv` is LUKS (keyfile unlock via crypttab); k3s waits for it
(`k3s.service` drop-in: `After=srv.mount`, `RequiresMountsFor=/srv`). After
`/srv` is up all hostPath pods come back on their own. Media stays intact
on the RAID; only k3s runtime (SSD, `/var/lib/rancher/k3s`) would be lost
on a root-disk failure.

Host networking (Phase 9.0, verified 2026-09-30): the real root uses
systemd-networkd (`/etc/systemd/network/10-lan.network`) +
systemd-resolved; dhcpcd is installed but disabled.
`network-online.target` waits until enp5s0 has routable IPv4 AND IPv6, so
docker/k3s never start pre-network (the cause of the 2026-09-30 "all Matter
devices unavailable" boot). The initramfs tinyssh unlock (`netconf` hook,
kernel `ip=:::::eth0:dhcp`) is separate and must not be changed. Checks:
`networkctl status enp5s0`, `resolvectl status`,
`bash bootstrap/host/network/verify-networkd.sh`. Rollback:
`sudo /usr/local/sbin/networkd-revert.sh` (reboots; `--no-reboot` to skip).

What a healthy reboot looks like since Phase 9 (verified 2026-09-30,
twice): DHCPv4 ~42 s -> DHCPv6 ~45 s -> Network Online ~46 s -> k3s ~55 s;
the home pods' containers are recreated ~10 s after that (lastState exit
255 "Unknown" = died with the node, RESTARTS shows 1 - that is the reboot
itself, not a crash). Expect WARNING "Startup probe failed" events for
matter-server during the first ~2 min (ConnectionRefused, then
nodes=12 available=0) - the semantic probe is WAITING for the nodes, which
is exactly its job; all 12 come back on their own within ~2-3 min. A
single boot-restart stays under the MatterServerRestarting threshold
(>2/h), so no false alert. Matter health at any time:
`kubectl -n home exec deploy/matter-server -- python3 /probe/health.py`.
Matter health at any time:
`docker exec -i matter-server python3 - < apps/home/matter-server/health.py`.

Home automation (Phase 9): Home Assistant runs in k3s and is VERIFIED
(2026-09-30: desktop+mobile login, Matter toggles, recorder writing to the
migrated DB). It is served at https://ha.home.jg-a.com and http://nas:8123
(`apps/home/home-assistant`, hostNetwork). matter-server ALSO runs in k3s
since 2026-09-30 (`apps/home/matter-server`, hostNetwork; fabric at
`/srv/appdata/matter-server`; HA connects over localhost:5580 like in
Docker). Matter health check:
`kubectl -n home exec deploy/matter-server -- python3 /probe/health.py`
(startupProbe/livenessProbe already run it; the alert
MatterServerRestarting fires if the liveness probe restarts it >2x/h).
Both Docker containers (`homeassistant`, `matter-server`) are stopped and
kept as rollback until ~2026-10-14: scale the deploy to 0, then
`cd /srv/homeassistant && docker compose start <service>` (use
http://nas:8123 for HA while rolled back; the Docker copy has no
trusted_proxies, so ha.home.jg-a.com would 400). Their config dirs were never
modified (rsync copies only; covered by the nightly snapshot + rclone
jobs). `ha.home.jg-a.com` needs HA's `http: trusted_proxies: [10.42.0.0/16]` (in the
migrated `configuration.yaml`); without it HA answers 400 to Traefik.

## k3s vs Arch packages (never fight pacman with k3s)

- k3s is ONE static binary at `/usr/local/bin/k3s` (get.k3s.io), embedding
  containerd, runc, kubelet, kube-proxy, CoreDNS, Flannel, Traefik,
  klipper-lb and its own iptables userspace. `/usr/local` is outside
  pacman; `pacman -Syu` cannot desync k3s from itself.
- Arch `containerd/runc/iptables` are Docker deps only (Docker leaves in
  Phase 9).
- Kernel upgrades take effect on reboot; required modules (`overlay`,
  `br_netfilter`, `vxlan`, conntrack/nat) are in-tree. k3s then waits for
  `/srv` and everything comes back.
- NEVER install `k3s`/`k3s-bin` from the AUR (would tie a Kubernetes minor
  jump to `yay -Syu`). Do not install Arch `kubectl` - use the
  `/usr/local/bin/kubectl` symlink to `k3s kubectl`. Arch `helm` is fine
  (client only).
- k3s upgrade: edit `K3S_VERSION` in `bootstrap/k3s/install.sh`, commit,
  `sudo bash bootstrap/k3s/install.sh` (restarts k3s; running pods survive;
  API gone ~20 s). One Kubernetes minor at a time; read the release notes.
  Rollback = set the old version, rerun.

## Updating (Dependabot)

All image tags are pinned; no `:latest`/`:stable`. Dependabot (docker
ecosystem on `/apps/**`, helm on the umbrella chart) opens weekly PRs
grouped by type (linuxserver images together, exporters together,
HA/matter together).

- Workflow: merge PR -> `make apply-media` / `kubectl apply -k ...`
  (Recreate strategy restarts the pod) or `make apply-observability` for
  the chart. Rollback = `git revert` + apply.
- Alerts arrive as Dependabot PRs; verify the tag shape parses
  (`X.Y.Z-rN-lsNNN` builds bump; if Dependabot cannot parse them, switch
  that app to LSIO's `version-X.Y.Z` tags).
- Limitations accepted: `K3S_VERSION` in the shell script is manual,
  deliberate; "matter-server <= what HA requires" is enforced by reading HA
  release notes (grouped PRs); Jellyfin plugins (Shokofin) update inside
  Jellyfin's plugin UI.
- Per-app cautions: Jellyfin minors run one-way DB migrations - snapshot +
  tar `/srv/appdata/jellyfin` first and confirm Shokofin compatibility;
  qBittorrent/arr never downgrade; kube-prometheus-stack majors need CRDs
  applied first (`kubectl apply --server-side -f <crds>` - the chart's
  upgrade notes say when); Home Assistant monthly releases: read breaking
  changes (Phase 9).
- Cadence: stateless/low-risk PRs anytime; stateful ones (Jellyfin, HA,
  Shoko, the chart) batch into a monthly window right after
  `pacman -Syu` + reboot so one reboot validates kernel + k3s + apps
  together.

## Backups

- `rclone-backup.timer` runs daily (drop-in adds the appdata sync):
  `/srv/appdata` -> B2 `John-System-Backups/appdata` (rclone `sync`), after
  `snapshot-sqlite.sh` takes consistent SQLite snapshots into
  `/srv/appdata/_snapshots/`, `snapshot-postgres.sh` dumps Nextcloud's
  PostgreSQL into `_snapshots/nextcloud/nextcloud.sql.gz` and
  `snapshot-mongo.sh` dumps LibreChat's MongoDB into
  `_snapshots/librechat/librechat-mongo.archive.gz` (all then synced).
- Exclusions (see the drop-in for the authoritative list): prometheus,
  jellyfin-cache, logs, wal/shm, the LIVE snapshotted DBs (grafana, shoko,
  jellyfin, seerr, bazarr, home-assistant, hermes state.db, joplin-cli
  profile db, openviking *.db, openclaw *.sqlite), the arr live DBs (their
  weekly zips in `<app>/Backups/` are the restore source - sonarr
  mid-import-waves tore its live DB reads and hard-failed the sync,
  2026-10-13),
  `postgres/**` (the pg_dump is the restore source), `librechat-mongo/**`
  (LC phase: the mongodump in `_snapshots/librechat/` is the restore
  source; LibreChat's `images/` + `uploads/` sync plainly), the Shokofin VFS
  symlink tree, nextcloud churn (nextcloud.log, uploads/, appdata_*), and
  `joplin-export/**` (AI phase: regenerable on the next */5 job run;
  the openviking vector index is likewise rebuildable via `ov reindex`;
  a stale openclaw memory index rebuilds via `openclaw memory index
  --force`).
- Radarr/Sonarr/Prowlarr additionally write weekly config zips to
  `<app>/Backups/`; qBittorrent BT_backup is copied live; the Matter
  fabric is a tiny json blob; `/srv/Media` is NOT backed up (torrents).
- Check: `systemctl status rclone-backup.service`,
  `rclone lsd Backblaze:John-System-Backups/appdata`.
- Disaster recovery: [disaster-recovery.md](disaster-recovery.md).

## Monitoring & alerting

- Prometheus targets: https://prometheus.home.jg-a.com (all ServiceMonitors picked up
  by design - selector is empty).
- Grafana: https://grafana.home.jg-a.com (admin creds in `secrets/grafana.env`;
  dashboards load automatically from `apps/observability/dashboards/`
  ConfigMaps - edit there, or import in the UI then export back).
- Alertmanager: https://alertmanager.home.jg-a.com - currently ONE null receiver (all
  alerts visible in the UI only; nothing phones anyone). Adding phone/email
  receivers later is a values-only change in
  `apps/observability/kube-prometheus-stack/values.yaml`.
- Custom rules: `apps/observability/rules/prometheusrule.yaml`
  (mdadm failed disks, /srv < 500 GB free, SMART unhealthy,
  MediaServiceDown for 10m; home: MatterServerRestarting,
  MatterNodesUnavailable, MatterServerUnreachable, HomeAssistantDown;
  ai: OpenVikingDown - SUSPENDED in the OC phase, whole rule group
  commented out while openviking is disabled; revert per operations.md
  "AI ops").
- TLS rules: `apps/observability/rules/cert-manager.yaml`
  (CertificateNotReady, CertificateExpiringSoon <14d,
  CertificateScrapeMissing; metrics scraped via
  `apps/observability/exporters/cert-manager.yaml`). See [tls.md](tls.md).
- Matter semantics (phase 9): `matter-exporter`
  (`apps/observability/exporters/matter.yaml`, scrapes the WS API at
  10.0.0.4:5580 like health.py) exports `matter_up`, `matter_nodes`,
  `matter_nodes_available`, `matter_scrape_duration_seconds`.
  `MatterNodesUnavailable` (available == 0 while up, 5m) is the ONLY
  alert that sees the 2026-09-30 failure mode (port listening, HA
  connected, no restarts, all nodes stuck unavailable).
- Home Assistant metrics (9c, active 2026-09-30): HA's built-in
  `prometheus:` integration scraped at /api/prometheus with a long-lived
  token (Secret `homeassistant-token` in ns home); job label is
  `home-assistant`. Exposes `homeassistant_entity_available` (116
  entities), `homeassistant_state_change_total`,
  `homeassistant_light_brightness_percent` (the lights),
  `process_*` for HA RSS/CPU.
- Grafana dashboard "Home (Home Assistant + Matter)" (uid `home-matter`,
  `apps/observability/dashboards/home.yaml`): node availability, exporter
  health, home pod restarts/memory, HA entities/activity/RSS, light
  brightness.
- Test anytime: `kubectl -n media scale deploy/radarr --replicas=0` for
  ~11 minutes -> MediaServiceDown + TargetDown fire in Alertmanager.

## Service endpoints

| App | URL | Legacy |
|---|---|---|
| qBittorrent | https://qbit.home.jg-a.com | http://nas:8080 |
| Jellyfin | https://jellyfin.home.jg-a.com | http://nas:8096 |
| Prowlarr | https://prowlarr.home.jg-a.com | |
| Radarr | https://radarr.home.jg-a.com | |
| Sonarr | https://sonarr.home.jg-a.com | |
| Bazarr | https://bazarr.home.jg-a.com | |
| Seerr | https://seerr.home.jg-a.com | |
| Shoko | https://shoko.home.jg-a.com/webui/ | |
| Grafana | https://grafana.home.jg-a.com | |
| Prometheus | https://prometheus.home.jg-a.com | |
| Alertmanager | https://alertmanager.home.jg-a.com | |
| Home Assistant | https://ha.home.jg-a.com | http://nas:8123 |
| Nextcloud | https://nextcloud.home.jg-a.com | |
| Hermes (AI) | https://hermes.home.jg-a.com (dashboard, basic auth) | |
| Hermes API (AI, H2: Conduit) | https://hermes-api.home.jg-a.com (OpenAI-compatible API server; API_SERVER_KEY bearer) | |
| Matrix (MX phase) | https://matrix.home.jg-a.com (tuwunel homeserver; federation OFF, registration closed after onboarding) | |
| Element (MX phase) | https://element.home.jg-a.com (Element Web client for the homeserver) | |
| OpenViking (AI) | https://openviking.home.jg-a.com (Web Studio at `/studio`) | |
| OpenClaw (AI, H2 phase: disabled) | ~~https://openclaw.home.jg-a.com~~ (Control UI; gateway-token auth) | |
| Letta (AI, H2 phase: disabled) | ~~https://letta.home.jg-a.com~~ (App Server; LETTA_APP_SERVER_TOKEN auth) | |

All web UIs require login (qBittorrent: LAN 10.0.0.0/24 bypass + creds for
apps; Radarr/Sonarr/Prowlarr/Bazarr/Shoko/Seerr/Grafana: forms). Nextcloud:
family instance - owner `john` (admin, TOTP enforced) + `family` group
members; all users are on the LAN or VPN (WireGuard DNS is set in the peer
generator, manual, out of scope here). `./scripts/nc-occ.sh` wraps occ.

## Nextcloud ops (NC phase)

- **occ**: `./scripts/nc-occ.sh <args>` (e.g. `status`, `user:list`).
- **Accounts**: family members = regular users, added via
  `./scripts/nc-occ.sh user:add --email <a@b.c> <name>` then
  `occ group:adduser family <name>` (email REQUIRED - password resets are
  emailed; SMTP must be configured first, see below). Default quota
  100 GB/user (`files default_quota` appconfig); `john` is unlimited.
- **SMTP (PENDING - owner to fill `secrets/nextcloud.env` SMTP_* keys,
  then `make apply-cloud` and `occ config:system:set mail_*` or the
  admin UI)**: needed for password resets, invites, share notifications.
- **Updates**: nextcloud/postgres/redis majors are MANUAL (Dependabot
  ignores semver-major): NC can upgrade ONE major at a time; do it in a
  window with `occ maintenance:mode --on`, snapshot + tar
  `/srv/appdata/nextcloud` + the pg_dump FIRST (Jellyfin-style caution,
  stricter); NC majors also require app-compat checks for
  memories/calendar/contacts. Minors/patches = merge the Dependabot PR,
  `make apply-cloud`, **then `./scripts/nc-occ.sh upgrade`** - MANDATORY:
  with subdir mounts the entrypoint starts every pod with an empty
  /var/www/html and takes the "new instance" path, so it CANNOT detect the
  version change and never runs occ upgrade (2026-10-16: 35.0.2 bump sat in
  upgrade-limbo - status.php worked but ALL OCS endpoints 503'd, cron
  refused, the exporter reported maintenance and NextcloudDown fired; the
  alert within ~10 min of an image bump = you forgot the upgrade step).
  Rollback = git revert + apply + occ downgrade is NOT supported - restore
  the pre-update pg_dump + tarball instead (take both before major jumps).
- **Probes/install envs**: the deployment has NO install envs by design -
  see the deployment.yaml comment (install envs are first-run only;
  steady-state config lives in the mounted config.php, occ-managed).
- **Monitoring**: nextcloud-exporter in observability; `NextcloudDown`
  (semantic `nextcloud_up` + exporter-absence) and
  `NextcloudScrapeErrors` (rotated serverinfo token is the usual cause -
  re-mint with `occ config:app:set serverinfo token` and update
  `secrets/nextcloud-exporter.env`). Grafana dashboard "Nextcloud".
- **Backups**: pg_dump pre-step + data dir in the nightly B2 sync (see
  Backups section + [disaster-recovery.md](disaster-recovery.md)).


## AI ops (Hermes + OpenViking + joplin-export; H2 phase - OpenClaw/Letta disabled)

Design + decisions: `docs/PLAN.md` H2 phase (2026-10-21) - this is the
revert the OC phase was built to allow, plus one new requirement: the
owner wants **Conduit** (mobile app) against the gateway, so the Hermes
**API server** is enabled (D8 amended - dashboard-only no longer covers a
phone client). Namespace `ai` (`apps/ai/`): **hermes** (gateway +
dashboard :9119 basic-auth + OpenAI-compatible API server :8642 -
`API_SERVER_ENABLED/HOST/KEY` envs, bearer auth, full agent toolset incl.
terminal behind the key; ingresses `hermes.home.jg-a.com` (dashboard) +
`hermes-api.home.jg-a.com` (API - Conduit points here); state
`/opt/data` -> `/srv/appdata/hermes` untouched since the AI phase,
image pin unchanged v0.22.2 - straight boot, no wizard), **openviking**
(memory/knowledge store, OpenRouter embeddings; ServiceMonitor +
OpenVikingDown un-suspended; state untouched, entrypoint self-starts on
ov.conf), **joplin-export** (CronJob */5 with the `ov add-resource` upsert
leg RESTORED - precise revert of OC-2/0f98098: `@openviking/cli@0.4.23`,
ovcli Secret mount, `ov language`, upsert into
`viking://resources/joplin`), **openclaw + letta DISABLED**
(`replicas: 0`, ingresses out of their kustomizations,
manifests/state/backups kept for revert - the hermes pattern, third
generation). Nothing reads the Nextcloud Joplin sync directory; no NC
service account or share exists.

### Go-live order (H2 phase - repo work is done; these are the owner steps)

1. Fill secrets: `API_SERVER_KEY` is already generated in
   `secrets/hermes.env` (`openssl rand -hex 32`) - rotate it if you want
   a value you picked yourself. `secrets/ovcli.conf` was never removed
   from disk (VERIFY: `ls secrets/ovcli.conf`).
2. Sanity-check the untouched state (sudo): `ls /srv/appdata/hermes`
   (config.yaml, .env, state.db, sessions/), `ls /srv/appdata/openviking`
   (ov.conf, data/) - everything should be exactly as the OC phase left
   it; neither wizard runs again.
3. Apply: `make apply-ai` **and** the alert rules (lighter than the full
   observability target):
   `kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/rules | kubectl apply -f -`
   (OpenVikingDown un-suspends). Netpol needs no edit - hermes/openviking
   never left the allow lists.
4. First live-run VERIFY items:
   - **C1 VERIFIED (2026-10-21, go-live lesson): hermes's own
     /opt/data/.env ALREADY carried an API_SERVER_KEY** (seeded by the
     AI-phase setup), and the s6 entrypoint's .env sourcing WINS over
     the k8s env - the injected key was rejected
     (`gateway_auth_failed`). Resolution: `secrets/hermes.env` was
     ALIGNED to the .env value (both stores agree). Rotation = change
     /opt/data/.env AND secrets/hermes.env together, or drop the .env
     line and let k8s env win. Working check:
     `curl -s -H "Authorization: Bearer $(grep -oP
     '(?<=^API_SERVER_KEY=).*' secrets/hermes.env)"
     https://hermes-api.home.jg-a.com/v1/models` lists `hermes-agent`;
     401 without the key.
   - C2 Conduit (Hermes connection): base URL
     `https://hermes-api.home.jg-a.com`, API key = `API_SERVER_KEY` -
     VERIFY whether its field wants the root or the `/v1` suffix (either
     maps to the same server); a chat turn streams; a tool call asks for
     approval on the phone.
   - C3 SSE streaming through Traefik: upstream sends 10s keepalives
     (built for 20s proxy idle deadlines) - if a stream dies at exactly
     60s, it's the NC-phase readTimeout lesson; check
     `cluster/traefik/helmchartconfig.yaml`.
   - C4 the memory gap: notes added between OC and H2 were never upserted
     into OpenViking (openclaw indexed them into its own SQLite instead).
     The first joplin-export run after this restore backfills them.
     VERIFY the first run fits the 600s job deadline (the AI-phase first
     sync overran and needed the one-off bootstrap pod
     `apps/ai/joplin-export/bootstrap-pod.yaml` - same trick if the
     backfill upsert overruns):
     `kubectl -n ai create job --from=cronjob/joplin-export joplin-export-manual`
     then check the pod logs for the `ov add-resource` output.
   - C5 memory recall end-to-end: `hermes memory status` (kubectl exec)
     -> openviking available; ask via Conduit about something only a
     Joplin note knows; `viking_search` finds a note in the Studio.
5. End-to-end checks:
   - `kubectl -n ai get deploy` -> hermes 1/1, openviking 1/1, letta
     0/0, openclaw 0/0; no OpenVikingDown firing (Prometheus target up
     again - `kubectl -n observability logs deploy/observability-kube-prometheus-prometheus` or the UI).
   - **GO-LIVE LESSON (2026-10-21, minutes after the H2 apply):
     OpenVikingDown + TargetDown fired because the openviking
     /metrics endpoint was DISABLED all along** - the scrape target
     existed but answered 404 "Prometheus metrics are disabled." and
     `up{job="openviking"}` had NEVER been 1 (9-day history, all three
     pod instances: the AI-phase ServiceMonitor was a dead scrape from
     day one; OC/LET masked it - rule commented out, replicas 0). The
     server ships metrics OFF by default. Fix (applied same day): add
     `"observability": { "metrics": { "enabled": true } }` to the
     `server` object of /srv/appdata/openviking/ov.conf (edit in-pod as
     root - the file is root-only on the host and never in git; member
     lines need their trailing commas) + `kubectl -n ai rollout
     restart deploy/openviking`; validated with the server's own
     loader (`openviking.server.config.load_server_config`). If
     /metrics ever 404s again, check that ov.conf key FIRST - the
     pods/health side is a red herring (the app was healthy the
     whole time).
   - Dashboard: https://hermes.home.jg-a.com loads, basic-auth login,
     old sessions/memories visible.
   - API: `curl -s https://hermes-api.home.jg-a.com/health` -> ok
     (unauthenticated by upstream design); `/v1/models` 401 without /
     200 with the key.
   - Conduit: chat turn streams, tool approval arrives, scheduled work
     lists (it only shows capabilities the server reports).
   - Joplin: edit a note on the desktop -> ~5-15 min later the export job
     upserts it and Hermes answers a question only that note answers
     (desktop sync + CronJob + upsert).

### Revert procedure (to Letta)

The OC phase's disable-not-delete pattern, third generation - state
dirs, secrets files, B2 backups, netpol entries and Dependabot pins were
never touched:

1. `apps/ai/letta`: `replicas: 1` (was 0), re-add `- ingress.yaml` to its
   kustomization.
2. hermes + openviking: `replicas: 0`, take `ingress.yaml` (+ hermes
   `ingress-api.yaml`, openviking `servicemonitor.yaml`) out of their
   kustomizations; re-comment the `ai` rule group in
   `apps/observability/rules/prometheusrule.yaml`; drop the ov leg from
   joplin-export again (git history: OC-2 0f98098 shows exactly what to
   remove).
3. `make apply-ai` + apply the rules kustomize (step 3 above).
4. `/srv/appdata/{hermes,openviking,letta,openclaw}` keep their state
   either way; each phase's runbook lives in this file's history.

### LC phase (LibreChat web front-end for Hermes) - 2026-10-26

Design + decisions: `docs/PLAN.md` LC phase (D18-D24). Namespace `ai`
(`apps/ai/librechat/`): **librechat** (`ghcr.io/librechat-ai/librechat:v0.8.8`
- FIRST-PARTY org GHCR, version-tagged; the stale `danny-avila` GHCR path and
the `:latest`-only `registry.librechat.ai` were rejected by the pin policy) +
**no-auth mongo** (`mongo:8.0.20`, upstream compose shape, behind the
default-deny). ONE custom endpoint in `librechat.yaml` (ConfigMap
`librechat-config`, config schema `version: 1.3.17`): "Hermes", baseURL
`http://hermes:8642/v1` **over the in-cluster Service** (D18 - so NO netpol
allow edits; egress = DNS + same-ns only, D22: librechat is deliberately NOT
in `ai-egress-internet-https` - all model traffic goes in-cluster to hermes),
apiKey `${HERMES_API_KEY}` interpolated from the Secret, server-side only.
Ingress `librechat.home.jg-a.com` -> 3080, no middleware (D24 - LibreChat's
own JWT login is the gate). Meilisearch/RAG skipped (not needed to chat);
upstream's `librechat-admin-panel` container out of scope, add later if
wanted.

#### Go-live order (LC phase - the owner steps)

1. `sudo bash bootstrap/host/phase-lc0.sh` - creates
   `/srv/appdata/librechat/{images,uploads}` +
   `/srv/appdata/librechat-mongo`, all owned 1000:1000 (both images run as
   an explicit UID:GID per upstream compose).
2. Fill `secrets/librechat.env` (generation commands in
   `secrets/librechat.env.example`). **`HERMES_API_KEY` MUST equal
   `API_SERVER_KEY`** - copy the value that lives in
   `/srv/appdata/hermes/.env` (`kubectl -n ai exec deploy/hermes -- grep
   '^API_SERVER_KEY' /opt/data/.env`) - the H2/C1 lesson: that store wins
   over the k8s env, so the two were ALIGNED. Rotate both together or not
   at all. `ALLOW_REGISTRATION=true` for first boot (D23).
3. `sudo cp bootstrap/host/rclone-backup-dropin.conf
   /etc/systemd/system/rclone-backup.service.d/override.conf` (new
   exclude: `librechat-mongo/**`, new ExecStartPre) **and** `sudo cp
   scripts/snapshot-mongo.sh /srv/appdata/_scripts/snapshot-mongo.sh` +
   `sudo chmod +x` - neither host file updates itself.
4. `make apply-cluster` (netpol header comment only - no allow changes) +
   `make apply-ai`.
5. First run: register the admin at https://librechat.home.jg-a.com,
   then flip `ALLOW_REGISTRATION=false` in `secrets/librechat.env` +
   `make apply-ai`.
6. VERIFY items - **VERIFIED 2026-10-26 (go-live), see lessons below**:
   - model list from Hermes `/v1/models`: **hermes v0.22.2 reports exactly
     ONE id, `hermes-agent`** (the gateway resolves models internally) -
     `models.default` + `titleModel` in `configmap.yaml` are pinned to it;
     `models.fetch: true` rides along fine.
   - a streamed chat turn end-to-end (SSE through Traefik - if it dies at
     exactly 60s, the NC readTimeout lesson applies);
   - a tool/terminal turn asks for approval / runs (full agent toolset
     behind the gateway key) and memory recall via OpenViking answers;
   - backup leg: `sudo systemctl start rclone-backup.service` ->
     `snapshot ok: _snapshots/librechat/librechat-mongo.archive.gz`;
     DR rehearsal leg: `kubectl -n ai exec -i deploy/librechat-mongo --
     mongorestore --archive --drop < librechat-mongo.archive.gz`;
   - node RAM headroom (`kubectl top nodes` - the two pods add ~2 GiB
     of limits onto the 31 GiB node).

#### GO-LIVE LESSONS (LC phase, 2026-10-26)

- **L1 - `JWT_REFRESH_SECRET` must be set BEFORE first boot.** The env
  example shipped without it; a blank value makes LibreChat silently use
  `/app/.env.temp` (process-local bootstrap creds) AND write that
  fingerprint into the one-way `librechatCredentialMetadata` marker.
  Upstream docs: "Changing an established key does not re-encrypt
  existing records... do not overwrite that marker instead of performing
  a controlled migration." If a real secret arrives after first boot,
  every restart logs `[credentials] Active fingerprints for
  JWT_REFRESH_SECRET do not match` forever. **Fix applied (DB was 25 min
  old, 1 user, 0 chats): drop the DB (`mongosh --eval
  'db.getSiblingDB("LibreChat").dropDatabase()'`) + rollout restart ->
  "New database detected. Credential fingerprints were recorded" (clean
  marker under the permanent creds) + re-create the admin via
  `kubectl -n ai exec -it deploy/librechat -- npm run create-user`
  (interactive password prompt; first user in a fresh DB = ADMIN role;
  registration stays locked).** Both secrets now live in
  `secrets/librechat.env` from boot. Debug trail: the marker is a doc
  `_id: 'primary'` in the `LibreChat` DB, `fingerprints` per key.
- **L2 - the schedules engine refuses to arm without proof of
  single-replica** ("this process cannot see other replicas'
  generations" -> scheduled-chats writes 503). Fix:
  `SCHEDULES_SINGLE_PROCESS=true` in the Deployment env - honest for
  `replicas: 1` + Recreate. Scale past 1 only with Redis
  (`USE_REDIS_STREAMS`).
- **L3 - expected noise after a DB reset:** stale browser JWTs log
  `[jwtLogin] JwtStrategy => no user found` warns until re-login;
  `METRICS_SECRET is not set` and the unreachable RAG API warn on every
  boot (metrics off = /metrics 401; RAG skipped by design - no
  Meilisearch in this deployment).

#### Revert procedure (drop LibreChat)

The disable-not-delete pattern, fourth generation:

1. `apps/ai/librechat/kustomization.yaml` + `apps/ai/kustomization.yaml`:
   drop the `librechat` entries; `replicas: 0` is unnecessary - removing
   the app from the kustomization deletes the Deployments/Services/
   Ingress; state dirs `/srv/appdata/{librechat,librechat-mongo}`,
   `secrets/librechat.env`, the snapshot script + drop-in lines and the
   Dependabot pattern all STAY.
2. `make apply-ai`; re-add `librechat` to the kustomizations to restore.

### MX phase (Matrix homeserver + Hermes bot) - 2026-10-28

Design + decisions: docs/PLAN.md MX phase (D1-D13). Namespace `ai`
(`apps/ai/tuwunel/` + `apps/ai/element-web/`): **tuwunel**
(`jevolk/tuwunel:v1.9.4` - the maintainer's FIRST-PARTY Docker Hub
registry; GHCR only publishes :latest/:preview/:main, which the pin
policy rejects) - Rust Matrix homeserver (conduwuit lineage), embedded
RocksDB (no DB sidecar), native sliding sync (Element X works);
federation OFF (D3 - LAN/VPN-only; the homeserver dials NOTHING and is
deliberately absent from ai-egress-internet-https), token-gated
registration then closed (D11), first registered user = admin
(grant_admin_to_first_user); ingresses matrix.home.jg-a.com (Service
named `matrix` - the in-cluster name everything dials) +
element.home.jg-a.com (static Element Web client, stateless, DNS-only
egress); server_name `matrix.home.jg-a.com` is PERMANENT (DB wipe to
change). **Hermes integration (D1)**: the gateway's NATIVE Matrix
adapter (hermes-matrix toolset - full agent tools incl. terminal,
approvals via ✅/❌/♾️ reactions, threads, voice notes) connects as
the bot `@hermes:matrix.home.jg-a.com` over the IN-CLUSTER Service
`http://matrix:8008` (D6 - zero netpol edits, the librechat->hermes
precedent); the MATRIX_* keys live in Hermes's OWN
/srv/appdata/hermes/.env (H2/C1: that store WINS over k8s env), with
MATRIX_ALLOWED_USERS=@john:... so the bot ignores everyone else.
Backups (D9): live RocksDB excluded; the DB restore source is the
MANAGED backup repo `_snapshots/tuwunel/` (RocksDB BackupEngine,
retention 7, TRIGGERED nightly by scripts/snapshot-tuwunel.sh sending
"!admin server backup-database" to the admin room over the C-S API);
media (`tuwunel-media/`) syncs plainly. Updates: tuwunel bumps run
RocksDB migrations at startup - the Deployment's
terminationGracePeriodSeconds: 1800 is upstream's --stop-timeout
guidance so a migration is never killed mid-way; merge a bump only
with a fresh managed backup first (Jellyfin-class caution). E2EE: the
bot runs UNencrypted (D7 - LAN-only, and the in-cluster hop is plain
HTTP anyway); encrypted rooms are allowed but OFF by default -
enabling E2EE for the bot later means VERIFYing mautrix+libolm in the
hermes image first (upstream: deleting crypto.db bricks the device
identity - not worth it on a LAN server).
**DM threading (2026-10-28, owner request)**: `MATRIX_DM_AUTO_THREAD=true`
in /srv/appdata/hermes/.env - every TOP-LEVEL DM message becomes a
synthetic thread root and each thread is its own session namespace
(verified in the v0.22.2 adapter source: DMs ignore session_scope and
follow MATRIX_DM_AUTO_THREAD/MATRIX_DM_MENTION_THREADS; rooms already
auto-thread by default via MATRIX_AUTO_THREAD=true). Usage model: NEW
topic = new top-level DM message (fresh isolated context); CONTINUE a
topic = reply INSIDE its thread (context accumulates there only).
Isolated = the conversational transcript; hermes's long-term memory
(OpenViking + curated memory) is shared across ALL threads by design
- "where are my screws" works from any thread. Alternative
(one-line .env swap if ever wanted): MATRIX_DM_MENTION_THREADS=true
instead - threads only on @hermes mentions, plain DM messages share
one session. Manual reply-in-thread isolation works with no config at
all. Existing messages are not retro-threaded - only new ones.

#### Go-live order (MX phase - the owner steps)

1. `sudo bash bootstrap/host/phase-mx0.sh` - creates
   /srv/appdata/tuwunel (RocksDB) + /srv/appdata/tuwunel-media +
   /srv/appdata/_snapshots/tuwunel, all 0:0 750 (the image runs as
   root - verified from the image config; if a bump ever switches to a
   non-root user the pod crash-loops on the RocksDB open and the dirs
   need re-chowning).
2. Fill `secrets/matrix.env` (generation commands in
   secrets/matrix.env.example): `TUWUNEL_REGISTRATION_TOKEN=$(openssl
   rand -hex 32)` + `TUWUNEL_ALLOW_REGISTRATION=true`.
3. `sudo cp bootstrap/host/rclone-backup-dropin.conf
   /etc/systemd/system/rclone-backup.service.d/override.conf` (new
   exclude `tuwunel/**` + new ExecStartPre) **and** `sudo cp
   scripts/snapshot-tuwunel.sh /srv/appdata/_scripts/` + `sudo chmod
   +x /srv/appdata/_scripts/snapshot-tuwunel.sh` - neither host file
   updates itself. Safe to copy this early: the pre-step skips loudly
   while no RocksDB DB exists yet (rollout window - the env file only
   appears at step 7) and hard-fails only once a DB is actually there
   without it (no silent backup hole).
4. `make apply-cluster` (netpol header comment only - NO allow changes)
   + `make apply-ai` -> tuwunel + element-web 1/1 (probes hit
   /_matrix/client/versions).
5. Register at https://element.home.jg-a.com with the registration
   token: **@john FIRST** (= admin via grant_admin_to_first_user),
   then the bot **@hermes**. Then flip TUWUNEL_ALLOW_REGISTRATION to
   `false` in secrets/matrix.env + `make apply-ai` (D11 - registration
   closed; re-open briefly for family members later, or use the
   admin-room user commands). NOTE (L1 below): the 2026-10-28 go-live
   hit an admin-transfer recovery instead - follow the GO-LIVE
   LESSONS sequence if @john registers as a NON-admin.
6. Mint the bot token + write Hermes's config (the H2/C1 store):
   ```
   curl -s -X POST https://matrix.home.jg-a.com/_matrix/client/v3/login \
     -H 'Content-Type: application/json' \
     -d '{"type":"m.login.password","identifier":{"type":"m.id.user","user":"@hermes:matrix.home.jg-a.com"},"password":"<bot password>","initial_device_display_name":"hermes-gateway"}'
   ```
   -> copy `access_token` from the response, then:
   ```
   kubectl -n ai exec -i deploy/hermes -- sh -c 'cat >> /opt/data/.env' <<'EOF'
   MATRIX_HOMESERVER=http://matrix:8008
   MATRIX_USER_ID=@hermes:matrix.home.jg-a.com
   MATRIX_ACCESS_TOKEN=<paste the token>
   MATRIX_ALLOWED_USERS=@john:matrix.home.jg-a.com
   EOF
   kubectl -n ai rollout restart deploy/hermes
   ```
7. Backup-trigger env (root-only, 600): mint a long-lived @john token
   (the same login curl with `"initial_device_display_name":
   "backup-script"`), find the admin room's internal ID (Element ->
   the admin room -> Settings -> Advanced), then:
   ```
   sudo tee /srv/appdata/_scripts/tuwunel-backup.env >/dev/null <<'EOF'
   TUWUNEL_ADMIN_TOKEN=<the @john backup-script token>
   TUWUNEL_ADMIN_ROOM_ID=!<internal room ID>:matrix.home.jg-a.com
   EOF
   sudo chmod 600 /srv/appdata/_scripts/tuwunel-backup.env
   ```
8. Set the home room (proactive/cron delivery target): DM @hermes
   from Element, then send `/sethome` in that room (Matrix clients may
   need the `!sethome` alias form).

#### GO-LIVE LESSONS (MX phase, 2026-10-28)

- **L1 - a UIAA registration probe with only a valid token CREATES A
  REAL ACCOUNT.** tuwunel (conduwuit-family behavior) COMPLETES the
  request: no username/password supplied -> it auto-generates a random
  localpart + a passwordless, guest-flagged user and returns
  200 + access_token. The 2026-10-28 token-validation probe thus
  created `@cpi5krogyo:matrix.home.jg-a.com`, which took
  `grant_admin_to_first_user` + the admin-room invite that were meant
  for @john (guest-flagged accounts do NOT show up in
  `!admin users list-users`). RULE: register the owner account FIRST;
  never probe the registration flow before it exists. RECOVERY (executed
  2026-10-28, works): with the probe account's access token (it IS the
  admin credential until transferred) send admin-room commands over the
  C-S API: `!admin users make-user-admin
  @john:matrix.home.jg-a.com` (NOT grant-admin - that subcommand does
  not exist on v1.9.4; check `!admin users -h`) -> @john gains admin
  AND auto-joins the admin room; then `!admin users deactivate
  @cpi5krogyo:matrix.home.jg-a.com` (once a second admin exists the
  last-admin guard no longer blocks it; deactivation kills the probe's
  own token mid-command - expected).
- **L2 - the admin-room-over-C-S-API round trip is VALIDATED LIVE**:
  `!admin server list-backups` sent via
  `PUT /_matrix/client/v3/rooms/<room>/send/m.room.message/<tx>`
  answered `No backups found.` in-room - the exact mechanism
  scripts/snapshot-tuwunel.sh depends on (C4's mechanism leg).
- L3 - Element Web "can't connect" on the first owner attempt resolved
  on retry; no server-side fault was ever found (DNS + TLS + Traefik +
  CORS preflight + UIAA token validation all verified green from the
  host). The pods take ~1 min from apply to Ready and an attempt in
  that window meets a Traefik 503, which the Element service worker
  then caches - hard-refresh is the first remedy for "can't connect"
  reports during any go-live.
- **L4 - `ip_source = "rightmost_x_forwarded_for"` 500s EVERY direct
  in-cluster request.** Header-based ip_source values resolve the
  client IP EXCLUSIVELY from the header; the hermes bot connects
  in-cluster (D6, http://matrix:8008 - no Traefik, no XFF), so every
  bot sync failed with `500: Can't extract client IP from configured
  ip_source` until the key was REMOVED from the toml (the default
  extractor scans proxy headers and falls back to the TCP peer:
  browser traffic keeps real client IPs via Traefik's appended XFF,
  the bot attributes to its pod IP - confirmed via
  `!admin users last-active`). Tradeoff: leftmost XFF is spoofable by
  a LAN client - accepted for a LAN-only server (it only shifts
  rate-limit attribution/logs; qBittorrent already grants the whole
  LAN a WebUI bypass). NEVER set a header-based ip_source while
  MATRIX_HOMESERVER bypasses Traefik. NOTE: ip_source changes need a
  tuwunel restart, and ConfigMap edits do NOT restart the pod - rollout
  restart manually after touching the toml.
- **C1 VERIFIED: hermes v0.22.2 ships the matrix adapter (mautrix
  included)** and connects with exactly the four env keys of go-live
  step 6 (MATRIX_HOMESERVER/USER_ID/ACCESS_TOKEN/ALLOWED_USERS - no
  newer-doc keys needed, E2EE off). The sync loop retries every 5s on
  errors and self-heals through homeserver restarts (observed twice,
  both tuwunel restarts of this go-live).
- **L5 - `kubectl exec` stdin appends REQUIRE `-i` - and a verification
  must never be masked by a fallback.** The 2026-10-28 DM-threading
  append ran `kubectl exec` WITHOUT `-i`: the heredoc never reached
  `cat`, nothing was appended, and the follow-up
  `grep MATRIX_DM_AUTO_THREAD ... || echo "(only DM_AUTO_THREAD set)"`
  printed a MISLEADING success message (grep's exit-1 = no match was
  swallowed by the fallback) - the setting silently never applied and
  the owner correctly reported "no auto-threading" from both Element
  Web and Element X. Rule: append with `exec -i` (exactly like runbook
  step 6), and verifications must POSITIVELY print the expected line -
  grep exit codes are the contract, `|| echo` fallbacks are for
  ABSENCES you expect, not for values you just wrote.

#### First live-run VERIFY items (MX phase)

- C1 hermes v0.22.2 MATRIX_* env surface: the upstream docs describe
  NEWER versions - after the restart, `kubectl -n ai logs deploy/hermes
  --tail=200 | grep -i matrix` must show the adapter CONNECT + SYNC,
  not "mautrix not installed" (the Docker build ships the matrix extra
  on Linux - VERIFY, don't assume). Unknown-key fallback: interactive
  `kubectl -n ai exec -it deploy/hermes -- hermes gateway setup`.
- C2 image UID: `ls -l /srv/appdata/tuwunel` after first boot -
  RocksDB files owned by root = expected.
- C3 registration closed after step 5: a fresh registration attempt is
  refused (M_FORBIDDEN) - the token path is gone.
- C4 backup leg: `sudo systemctl start rclone-backup.service` ->
  "snapshot ok: _snapshots/tuwunel updated"; `!admin server
  list-backups` in the admin room shows the fresh backup; full DR
  rehearsal leg per disaster-recovery.md (restore-pod.yaml).
- C5 clock skew: `timedatectl` -> "System clock synchronized: yes" -
  upstream gotcha: a host clock AHEAD of real time makes the bot drop
  EVERY message ("dropped N live events as 'too old'").
- C6 agent E2E from Element: DM @hermes -> streamed reply; a terminal/
  dangerous tool call -> approval reactions (✅ once / ♾️ always /
  ❌ deny); `!commands` (or /commands) works; ask something only a
  Joplin note knows -> memory recall via OpenViking answers.
- C7 media through Traefik: send a >10 MiB file to the bot over VPN -
  if it 502s at exactly 60s, the NC readTimeout lesson applies.
- C8 Element X (over WireGuard) + Element Web: login @john, sliding
  sync works, a sync connection stays alive for minutes (client
  long-polls are <= 30s).
- C9 `kubectl top nodes` - headroom for the two new pods (~1.1 GiB of
  limits total; trimmed RocksDB caches per D13).

#### Troubleshooting (MX phase)

- Bot silent despite greens: MATRIX_ALLOWED_USERS must use the FULL
  @user:server form; check the C5 clock skew; check hermes logs for
  "whoami failed" (token revoked/expired -> re-mint, re-write .env).
- Backup unit fails at snapshot-tuwunel: 401 = the admin token died
  (re-mint step 7); HTTP 503 = homeserver/ingress down; backup never
  lands = check `!admin server list-backups` output in the admin room.
- kubectl exec: the tuwunel image has NO shell - exec the binary
  directly, e.g. `kubectl -n ai exec deploy/tuwunel -- tuwunel --help`.
- Admin commands live in the ADMIN ROOM only (created at first boot;
  check the @john invite in Element): `!admin server ...`, `!admin
  users ...`, `!admin rooms ...`.

#### Revert procedure (drop Matrix)

The disable-not-delete pattern, fifth generation:

1. `apps/ai/kustomization.yaml`: drop the `tuwunel` + `element-web`
   entries (removing them from the kustomization deletes the
   Deployments/Services/Ingresses); state dirs
   `/srv/appdata/{tuwunel,tuwunel-media}`, `secrets/matrix.env`, the
   snapshot script + drop-in lines and the Dependabot pattern all STAY.
2. Hermes side: remove the MATRIX_* lines from /srv/appdata/hermes/.env
   (kubectl exec + sed -i) + `kubectl -n ai rollout restart
   deploy/hermes`.
3. `make apply-ai`; re-add the entries to restore.

### LET phase (historical - Letta go-live + revert runbooks)

Design + decisions: `docs/PLAN.md` LET phase (2026-10-21). Namespace `ai`
(`apps/ai/`): **letta** (App Server `ghcr.io/letta-ai/letta-code:0.34.19` -
first-party image, same tag the upstream deployment repo pins; port 4500,
`/readyz` probes, `LETTA_APP_SERVER_TOKEN` auth, env-driven - no onboard
wizard; state `/root/.letta` -> `/srv/appdata/letta`, OpenRouter provider),
**joplin-export** (CronJob */5: official Joplin CLI sync client -> clean
markdown export tree; letta's agent READS the tree via the read-only
`/mnt/joplin-export` mount + filesystem tools - NO indexed search, an
accepted degradation vs openclaw's `memory.search.extraPaths`), **hermes +
openviking + openclaw DISABLED** (`replicas: 0`, ingresses out of their
kustomizations, manifests/state/backups kept for revert - the OC phase
established the pattern and operations.md git history holds its runbooks).
Nothing reads the Nextcloud Joplin sync directory; no NC service account or
share exists.

#### Go-live order (LET phase - was the owner steps)

1. `sudo bash bootstrap/host/phase-letta0.sh` - creates `/srv/appdata/letta`
   (owned 0:0; the upstream image runs as root - VERIFY on first boot).
2. Fill secrets (placeholders committed as `*.example`):
   `secrets/letta.env` - `LETTA_APP_SERVER_TOKEN` (`openssl rand -hex 32`) +
   `OPENROUTER_API_KEY` (the same key every ai-ns agent has used since the
   AI phase).
3. `sudo cp bootstrap/host/rclone-backup-dropin.conf
   /etc/systemd/system/rclone-backup.service.d/override.conf` (new
   excludes: letta live sqlite/db) **and** `sudo cp
   scripts/snapshot-sqlite.sh /srv/appdata/_scripts/snapshot-sqlite.sh`
   (new letta snapshot loop) - neither host file updates itself.
4. `make apply-cluster` (netpol updates) and `make apply-ai`.
5. No interactive first run (unlike openclaw): the App Server is env-driven
   and starts straight from the Deployment. Create agents via the Agent
   SDK (remote backend, `https://letta.home.jg-a.com`, token auth) or the
   web UI.
6. First live-run VERIFY items - **ALL VERIFIED 2026-10-21 (go-live)**:
   - **VERIFIED, GO-LIVE LESSON: the image's DEFAULT command is the
     interactive CLI** - it printed help and exit 1'd (crash-loop) until
     `command:` was set in the Deployment. The App Server must be started
     explicitly: `letta server --backend local --listen ws://<bind> ...`.
   - **VERIFIED, GO-LIVE LESSON: `--listen <url>` and `--ws-auth` are
     REQUIRED for the deployment shape** - `--listen` with no url binds
     LOOPBACK ONLY (kubelet pod-IP probes + ingress can never reach it,
     the openclaw loopback-gate lesson recurring), and non-loopback
     listeners refuse to start without `--ws-auth capability-token` +
     `--ws-token-file`. Args cannot reference Secrets, so the Deployment
     command wrapper writes LETTA_APP_SERVER_TOKEN to a tmpfs file
     (emptyDir medium: Memory, umask 077) first.
   - **VERIFIED: /readyz answers 200 from the kubelet's pod-IP probes**
     (no openclaw-style loopback gate on the plain HTTP paths).
   - **VERIFIED: image runs as root** (`id` -> uid=0;
     `/srv/appdata/letta` stays 0:0).
   - **VERIFIED: HTTP/2 CURL PITFALL** - `curl` against an https WS URL
     negotiates HTTP/2 via ALPN, and HTTP/2 has NO Upgrade mechanism: the
     `Upgrade: websocket` headers are demoted to ordinary headers, Node
     never fires the upgrade event, and the app answers 403 (Origin) /
     404 (no route). It looks exactly like a broken ingress. Test WS
     handshakes with `curl --http1.1` - or accept curl hanging (exit 28
     after `101 Switching Protocols` = the handshake WORKED).
   - State format: no SQLite in /root/.letta yet at go-live (agents are
     created on first use - settings.json + system-cron dirs only);
     re-check after the first agent exists (the snapshot loop is a
     harmless no-op meanwhile).
   - Memory limit 2Gi: no OOMKills at go-live.
   - End-to-end VERIFIED: WS `101 Switching Protocols` + valid
     `Sec-Websocket-Accept` through Traefik with the bearer token, `401`
     on bad/missing token (fails closed), `/readyz` 200 via the ingress.

#### Revert procedure (to OpenClaw) (LET phase, historical)

Everything upstream (Nextcloud, Joplin desktop, app password, secrets
files) never changed; the state dirs and B2 backups were never touched
(openclaw's snapshot loop + rclone excludes stay in place while disabled):

1. `apps/ai/openclaw`: `replicas: 1` (was 0), re-add `- ingress.yaml` to
   its kustomization.
2. `apps/ai/letta`: scale to 0 (`kubectl -n ai scale deploy/letta
   --replicas=0`) or delete its manifests - owner's call;
   `/srv/appdata/letta` retains its state either way. `make apply-ai`.
   (`secrets/letta.env`, the netpol list entry and the Dependabot pattern
   can stay - they are needed again only on a future re-enable.)
3. No openclaw onboard rerun needed: its state dir
   `/srv/appdata/openclaw` (incl. `openclaw.json`, agents, memory) was
   never touched while disabled. If a `doctor`-style upgrade happened
   upstream while disabled, the Dependabot PR + `openclaw doctor --fix`
   startup path handles the migrations (see Updates below).
4. Reindex the Joplin tree in case notes changed while openclaw was down:
   `kubectl -n ai exec deploy/openclaw -- openclaw memory index --force`
   (then `openclaw memory status`).
5. Verify per the OC-phase checklist below (operations.md git history +
   `docs/PLAN.md` OC phase).

### OC phase (historical - OpenClaw go-live + revert runbooks)

Design + decisions: `~/.opencode/plan/openclaw-joplin.md` (D10-D17;
supersedes the AI-phase plan `~/.opencode/plan/hermes-openviking-joplin.md`,
kept for the revert rationale). Namespace `ai` (`apps/ai/`): **openclaw**
(agent gateway + web Control UI + builtin memory: `MEMORY.md` +
`memory/*.md` indexed into a per-agent SQLite with OpenRouter embeddings),
**joplin-export** (CronJob */5: official Joplin CLI sync client -> clean
markdown export tree; openclaw indexes the tree READ-ONLY via
`memory.search.extraPaths` - D13), **hermes + openviking DISABLED**
(`replicas: 0`, manifests/state/backups kept for revert). Nothing reads the
Nextcloud Joplin sync directory; no NC service account or share exists.

#### Go-live order (repo work was done; these were the owner steps)

1. `sudo bash bootstrap/host/phase-oc0.sh` - creates `/srv/appdata/openclaw`
   (owned 1000:1000 = the image's `node` user).
2. Fill secrets (placeholders committed as `*.example`):
   `secrets/openclaw.env` - `OPENCLAW_GATEWAY_TOKEN` (`openssl rand -hex 32`)
   + `OPENROUTER_API_KEY` (the same key Hermes/OpenViking used).
3. `sudo cp bootstrap/host/rclone-backup-dropin.conf
   /etc/systemd/system/rclone-backup.service.d/override.conf` (new
   excludes: openclaw live sqlite) **and** `sudo cp
   scripts/snapshot-sqlite.sh /srv/appdata/_scripts/snapshot-sqlite.sh`
   (new openclaw snapshot loop) - neither host file updates itself.
4. `make apply-cluster` (netpol updates) and `make apply-ai`.
5. OpenClaw first run (interactive, one-off). The gateway FAILS CLOSED on
   an empty state dir ("Gateway start blocked: existing config is missing
   gateway.mode" - 2026-10-20 go-live lesson; unlike OpenViking there is
   no pending health server), so the Deployment crash-loops until
   onboard has run. First-run happens in a one-off pod sharing the same
   hostPath state (`apps/ai/openclaw/bootstrap-pod.yaml`, the
   joplin-export bootstrap precedent):
   ```
   kubectl -n ai scale deploy/openclaw --replicas=0
   kubectl apply -f apps/ai/openclaw/bootstrap-pod.yaml
   kubectl -n ai exec -it openclaw-bootstrap -- openclaw onboard \
     --mode local --no-install-daemon --skip-channels
   ```
   - provider: OpenAI-compatible -> OpenRouter base URL
     (`https://openrouter.ai/api/v1`) + `OPENROUTER_API_KEY` (injected env);
     model = owner's choice, >=64K context (D16).
   - gateway auth: token - answer the prompt or let it read
     `OPENCLAW_GATEWAY_TOKEN` from the environment (`--gateway-auth token
     --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN`). VERIFY the exact
     non-interactive flags on the pinned version.
   - In `openclaw.json` after onboard (see openclaw.json.example):
     `gateway.bind: lan`, `gateway.controlUi.allowedOrigins:
     ["https://openclaw.home.jg-a.com"]`, and the memory block
     (`memory.search.extraPaths` -> `/mnt/joplin-export` +
     `**/*.md` pattern, embeddings provider -> OpenRouter). VERIFY each
     key against the pinned version's configuration reference.
   - NO channels (D14); the bootstrap pod injects the token as an env var
     so onboard can consume it without pasting into a terminal.
   - Verify then hand over to the Deployment:
   ```
   kubectl -n ai exec openclaw-bootstrap -- cat /home/node/.openclaw/openclaw.json
   kubectl -n ai delete pod openclaw-bootstrap
   kubectl -n ai scale deploy/openclaw --replicas=1
   ```
6. Reindex the Joplin tree once the first CronJob run has populated it:
   `kubectl -n ai exec deploy/openclaw -- openclaw memory index --force`
   (then `openclaw memory status`).

#### First live-run VERIFY items (OC phase)

- VERIFIED 2026-10-18 (joplin CLI, unchanged): one-shot commands are
  non-interactive by default (NO `--non-interactive` flag exists); sync
  target 6 = WebDAV; the FIRST `joplin sync` downloads the whole vault and
  can exceed the 600s job deadline (bootstrap once with
  `apps/ai/joplin-export/bootstrap-pod.yaml`).
- `openclaw onboard --non-interactive ...` flag surface on the pinned
  version (C2) - interactive `kubectl exec` onboard is the fallback and is
  what step 5 above assumes.
- `memory.search.extraPaths` key shape + glob semantics on the pinned
  version (C4); deletion propagation from extraPaths (C6) - a note deleted
  in Joplin must drop out of the index after a cycle. Fallbacks:
  pattern-scope the index, accept staleness, or schedule
  `openclaw memory index --force`.
- OpenRouter actually serves the chosen embedding model through the
  generic OpenAI-compatible provider block (C5). Fallback: keyword-only
  memory search (documented degradation, D15).
- The export tree must be READABLE by the openclaw runtime UID: it is
  750, owner 1000:1000 (the CronJob's user) and the openclaw image runs as
  `node` (1000) - same UID, works. VERIFY with `ls` if the image user ever
  changes (C7).
- VERIFIED 2026-10-20 (go-live): the gateway FAILS CLOSED on an empty
  state dir ("Gateway start blocked: existing config is missing
  gateway.mode"; no pending health server unlike OpenViking) - first-run
  onboard happens in a one-off bootstrap pod
  (`apps/ai/openclaw/bootstrap-pod.yaml`), not via kubectl exec on the
  Deployment, which crash-loops until configured.
- **Cluster change (traefik, 2026-10-20):** the k3s klipper svclb
   hostPort pods MASQUERADE all LoadBalancer hostPort traffic (DNAT to
   nodeIP:nodePort + `POSTROUTING -j MASQUERADE` inside the svclb pod
   netns), so X-Forwarded-For could never carry a real client IP and
   openclaw's Control UI answered `403 proxy_attribution_required`
   (its attribution needs a non-loopback, NON-TRUSTED-CIDR hop in the
   XFF chain - `trustedProxies: [10.42.0.0/16]` + XFF `10.42.0.1` =
   whole chain trusted = unattributable). Fix in
   `cluster/traefik/helmchartconfig.yaml`: Service type NodePort
   (klipper stands down - it only manages LoadBalancer Services) +
   `ports.web/websecure.hostPort` 80/443 (kubelet hostPort DNAT
   preserves source IPs; DNS `*.home.jg-a.com` -> nodeIP -> traefik pod
   unchanged). Verified: XFF carries real LAN IPs; all other hostnames
   work; qbit/jellyfin svclb pods unaffected. Chart-value pitfalls
   learned: `service.spec` is allow-listed (`.annotations` does not
   exist there), and the valuesContent must keep ONE top-level `ports:`
   key - a duplicate top-level key is silently dropped by the YAML
   parser.
- Embeddings index identity: changing the embedding provider/model pauses
  search until `openclaw memory index --force` (upstream behavior) - that
  is the runbook answer to "search stopped returning results" after a
  config change.

#### End-to-end checks (OC phase)

- `curl https://openclaw.home.jg-a.com/healthz` (or in-pod) -> ok; Control
  UI loads over the ingress and authenticates with the gateway token.
- A chat turn answers via OpenRouter (model configured at onboard).
- Edit a note on the desktop -> ~5-15 min later openclaw can answer a
  question only that note answers (desktop sync + CronJob export + the
  gateway's debounced reindex of the read-only mount).
- Delete a note in Joplin -> it drops out of memory search after a cycle.
- "Remember that I keep screws in the garage drawer" -> NEW session -> ask
  where the screws are -> recalled (the answer is in
  `/srv/appdata/openclaw/workspace/MEMORY.md` or `memory/*.md` - human
  curable with any text editor).
- `kubectl -n ai create job --from=cronjob/joplin-export joplin-export-manual`
  completes green (no ov leg anymore).
- `kubectl -n ai get deploy` -> openclaw 1/1, hermes 0/0, openviking 0/0;
  no OpenVikingDown firing (its rule group is commented out in
  `apps/observability/rules/prometheusrule.yaml`).

### Updates

- Dependabot "ai" group (hermes + openviking active again in H2; letta +
  openclaw disabled-but-listed for the revert paths) -> merge PR ->
  `make apply-ai` (Recreate restarts pods). hermes/openviking bumps now
  matter again: hermes state must match the image (hermes runs its own
  state migrations on start - keep pre-upgrade snapshots; openviking's
  vector index rebuilds via `ov reindex` if corrupt). letta releases
  were frequent npm/container tags (`0.x.y`); if PR volume for the
  disabled pair gets annoying, add ignore rules instead of delisting.
- openclaw (OC phase, historical): the image entrypoint runs
  `openclaw doctor --fix` on start: agent DB schema migrations happen
  under maintenance ownership with pre-migration `.bak` copies kept in
  the state dir - KEEP those with the pre-upgrade backup
  (disaster-recovery.md). Startup exit code 78 = "refused to migrate
  unsafe state" (source identity conflicts, another writer, unwritable
  state) - do NOT delete lock files; see the upstream health/docs flow
  instead. Rollback = `git revert` + `make apply-ai` + restore any
  `.bak`/snapshot the doctor took (the DB state must match the image).
- npm pins inside `apps/ai/joplin-export/run.sh` (joplin 3.7.1,
  @openviking/cli 0.4.23 - H2 restore) are manual, like K3S_VERSION;
  bump the joplin CLI in step with the desktop client's Joplin version.

#### Revert procedure (to Hermes + OpenViking) (OC phase, historical - EXECUTED 2026-10-21 as the H2 phase, see above)

Everything upstream (Nextcloud, Joplin desktop, app password, secrets
files) never changed; the state dirs and B2 backups were never touched:

1. `apps/ai/hermes` + `apps/ai/openviking`: `replicas: 1`, re-add
   `ingress.yaml` (+ `servicemonitor.yaml`) to their kustomizations.
2. `apps/observability/rules/prometheusrule.yaml`: un-comment the `ai`
   rule group.
3. `apps/ai/joplin-export/run.sh` + kustomization: restore the ov CLI leg
   from git history (npm install `@openviking/cli`, the ovcli.conf Secret
   mount, `ov add-resource ... --to viking://resources/joplin`);
   `secrets/ovcli.conf` is still on disk.
4. `make apply-cluster` + `make apply-ai`; verify per the ORIGINAL plan's
   AI-2/AI-3 checklists (operations.md git history / the AI-phase plan).
5. openclaw: scale to 0 (`kubectl -n ai scale deploy/openclaw
   --replicas=0` - or delete its manifests, owner's call).
   `/srv/appdata/openclaw` retains its state either way.

### Troubleshooting

- Logs: `kubectl -n ai logs deploy/openclaw --tail=200`; job logs for
  joplin-export (the export tree swap is visible in them).
- OOM (2026-10-20 go-live lesson): the Control UI's model/test-connection
  probe OOMKilled the pod at the original 2Gi limit (steady-state RSS
  ~1.6GiB with ~20 workers: prepared-model-catalog + session-transcript +
  sqlite workers hold ~1GiB heap alone). Limit is 4Gi now
  (deployment.yaml); the pod Recreate-restarts cleanly (SQLite clean-close
  receipts in the logs) and the browser device pairing + token survive
  (state is on the hostPath). If it OOMs again, `openclaw gateway
  diagnostics export` inside the pod reports the worker breakdown.
- Model "Test Connection" failing while chat works (2026-10-20 go-live
  lesson, ROOT CAUSE FOUND in /app/dist): the UI probe generates with a
  HARD-CODED `PROBE_MAX_TOKENS = 8` and inherits the agent
  `thinkingDefault` - with `thinking=medium` (the onboard default) the
  reasoning model burns all 8 tokens on reasoning before any content ->
  EMPTY content -> "The connection check failed" even though the API
  call returned HTTP 200 (gateway log shows `[model-fetch] response
  provider=openrouter ... status=200` right next to the failed probes).
  There is NO separate probe/chat thinking knob (the probe module has
  no thinking handling; the CLI's --probe-max-tokens flag is not used
  by the UI button). ACCEPTED POSTURE: keep
  `agents.defaults.thinkingDefault: medium` (good for real chats) and
  treat the Test Connection button as UNRELIABLE FOR REASONING MODELS -
  a green chat turn is the real connection test. Diagnostic if the
  probe fails: `[model-fetch] response ... status=200` in gateway logs
  + a chat turn. (`openclaw models status --probe` refuses to run while
  the gateway owns the state dir - by design.)
- Stale auth profiles (2026-10-20): each UI/CLI model-setup retry saved
  a new `openrouter:setup-*` auth profile in the agent SQLite; the UI
  probe iterates ALL of them (the 4 error lines were 3 stale profiles +
  the configured credential). Cleaned with `openclaw models auth logout
  <id> --yes` (the plain form refuses without --yes). The deployment's
  env SecretRef is what actually authenticates - the stored profiles
  were redundant duplicates.
- Health: `/healthz` (liveness AND readiness - GO-LIVE LESSON 2026-10-20:
  `/startupz` + `/readyz` answer 403 to non-loopback clients even with the
  token, so the kubelet's pod-IP probes can never pass; both probes use
  /healthz)
  in-pod or via the ingress; authenticated deep snapshot:
  `kubectl -n ai exec deploy/openclaw -- node dist/index.js gateway health
  --token "$OPENCLAW_GATEWAY_TOKEN"`.
- Memory: `openclaw memory status --deep` (index + embedding provider),
  `openclaw memory index --force` (rebuild), `openclaw memory search
  "query"` (test retrieval from the CLI).
- Sync-lock contention with the desktop client: the job is Forbid + 600s
  deadline; if runs start dying on the .lock, widen the schedule.
- The openclaw pod has NO kubeconfig, NO NC mounts, NO docker socket - if a
  task seems to need them, that is by design (D6); agent sandboxing is
  deferred (plan §8) - the pod boundary + default-deny netpol is the
  isolation today.
- Joplin export tree looks stale: check the CronJob logs first (joplin
  reports "Completed" even on connection errors - check the profile DB,
  not stdout, 2026-10-18 lesson).


## Known quirks (learned during migration)

- qBittorrent 5.2 returns HTTP 204 (no "Ok." body) on login: Radarr needs
  >= 6.3.0, exporters must set `QBITTORRENT_COOKIE_NAME=QBT_SID_8080`.
- Prowlarr indexers are tested at creation time - a down site (Anidex was
  502) blocks adding until it recovers.
- Traefik hostPorts are iptables DNAT, not LISTEN sockets - `ss -tln`
  shows nothing on :80; test with curl.
- Scale-to-0 removes ServiceMonitor targets (absence != down): the
  MediaServiceDown alert works via the exporters' own health, not the app
  endpoints.
- systemd-resolved caches negative DNS answers: right after adding an
  Unbound host override the host itself may still serve the old NXDOMAIN
  for a while (`getent hosts ha.home.jg-a.com` empty). Query OPNsense directly to
  check the record: `nslookup ha.home.jg-a.com 10.0.0.2` from a busybox pod.
- Home Assistant's habluetooth "Missing NET_ADMIN/NET_RAW capabilities"
  ERROR appears on every start, including in Docker - Bluetooth is not in
  use (no bluetooth config entry, no dbus mount); ignore it.
- ServiceMonitors select SERVICES by their metadata labels - a Service
  with no labels is silently never scraped (jellyfin was target-less from
  phase 7 until 2026-09-30; fixed by labelling the Service `app: jellyfin`).
- Nextcloud image bumps need `./scripts/nc-occ.sh upgrade` after
  `make apply-cloud` (see the Nextcloud ops section): with subdir mounts
  the entrypoint cannot see the old version and skips occ upgrade - the
  instance then serves plain pages fine while ALL OCS endpoints 503,
  cron.php refuses and the exporter reports maintenance. NextcloudDown
  firing right after an image bump is exactly this.
- Post-reboot 2026-10-16 (kernel 7.2.10 + k3s 1.36.5 + new systemd, all
  in one window): k3s's first start hit "unable to initialize network
  policy controller: error getting node subnet: failed to get list of
  links: results may be incomplete or inconsistent" (a netlink dump raced
  ongoing networkd address/route churn ~2 s after start), crashed once
  and systemd-restarted into a healthy node within seconds. One data
  point - if it recurs on the next reboot, add a short settle delay to
  the k3s drop-in. Matter still recovered 12/12 without manual action.
- A pod's own Service gets Docker-link-style env vars injected
  (`MATTER_EXPORTER_PORT=tcp://10.43.x.x:9566` for the matter-exporter
  Service). Name script env vars so they cannot collide
  (`MATTER_EXPORTER_LISTEN_PORT`).
- The prometheus-operator API group is `monitoring.coreos.COM` - `.io`
  fails with a confusing "no matches for kind ServiceMonitor" that looks
  like a missing CRD. (kustomize + apply won't catch it; a server
  dry-run will.)
- OpenViking (AI phase): the image entrypoint AUTO-STARTS the server the
  moment ov.conf appears - a manual `openviking-server` inside the pod
  fails on the port/workspace lock (the "error" is benign; the managed
  server is fine). Its pending health server answers 503 on /health
  while waiting for ov.conf BY DESIGN, so the startup probe window must
  cover the interactive `init` session (30 min; 300s killed the container
  3x mid-wizard and aborted the exec each time, 2026-10-18).
- joplin-export (AI phase): `npm install joplin` (sharp native deps)
  OOMKilled every run at a 512Mi limit with completely EMPTY logs - died
  before the first output line. Limit is now 2Gi and the npm output is
  never silenced (empty logs made the failure point indistinguishable,
  2026-10-18).
- joplin-export npm registry flakiness (2026-10-26, H2): a transient
  registry.npmjs.org tarball 404 (`bowser-2.15.0.tgz`) failed BOTH pods
  of a job (backoffLimit 1) and paged KubeJobFailed - while the pinned
  CLIs were already installed and fine. The per-run
  `npm install -g` was pure registry-fragility surface: with exact
  version pins + a persistent prefix, run.sh now SKIPS npm install
  entirely in steady state (checks package.json version of
  joplin + @openviking/cli in $NPM_PREFIX) and only hits the registry on
  first run / version bump (--prefer-offline + one retry). Corollary:
  the generic KubeJobFailed pages on ANY single failed tick, including
  self-healed transients - JoplinExportFailingStreak
  (apps/observability/rules/prometheusrule.yaml) is the real signal: >=2
  failed Job objects in the 24h ttl window means the */5 schedule is NOT
  self-healing. Half-written npm tree after an OOM-killed install (npm
  writes package.json before unpacking): rm -rf
  /srv/appdata/joplin-cli/npm and the next run reinstalls.
- joplin-export backup-storm deadline overrun (2026-10-27, H2): the
  07:20 UTC (00:20 PDT) slot failed DeadlineExceeded mid-sync - the
  nightly rclone backup (00:00-01:00 PDT) had all four array disks at
  ~0.9 io-time; joplin startup went 0.8s -> 55s (node_modules + sqlite
  on the array, Nextcloud WebDAV reads the same array) and the sync could
  not finish inside the 300s activeDeadlineSeconds. The next slot
  self-healed. Deadline is now 600s (Forbid makes an overrunning slot
  just SKIP the next one - a slow-but-completing run is not a failure);
  observed durations: p50 10s, backup/storm windows 64-120s. Diagnosis
  gold that survives the 24h job ttl: Prometheus
  `kube_job_status_failed{reason="DeadlineExceeded"}` +
  `job_name=~"joplin-export-.*"` history, and the persistent CLI log
  `/srv/appdata/joplin-cli/profile/log.txt` (its timestamps are UTC).
  Also: single failed joplin ticks no longer page (KubeJobFailed
  null-route in kube-prometheus-stack values.yaml, 2026-10-28) -
  JoplinExportFailingStreak (>=2 in the ttl window) is the real signal.
- k3s netpol + Traefik paths (AI phase, 2026-10-18 - THE big one): an
  egress allow for traffic dialed to `*.home.jg-a.com` must include
  Traefik's CONTAINER ports - the k3s traefik chart maps svc 443 ->
  targetPort 8443 and svc 80 -> 8080, and the DNAT chain delivers the
  packet to the traefik POD with the CONTAINER port before the egress
  policy evaluates. Allowing only 443/80 rejects every enforced
  connection. Diagnosis gold: capture the policy chains' own NFLOG
  drops from a privileged hostNetwork pod (`tcpdump -i nflog:100`)
  while connecting - it shows the true post-NAT dst:port.
- k3s netpol enforcement LAGS pod creation by seconds-to-a-minute: a
  fresh pod has no KUBE-POD-FW-* chain yet and is effectively
  UNRESTRICTED, then gets enforced. This made quick one-shot curl test
  pods "pass" a broken rule for hours while real (longer-lived) pods
  failed it - and made the failure look image- or uid-dependent, and
  made `sudo systemctl restart k3s` look like the fix (the state after
  any restart/churn re-runs the same race). VERIFY NETPOL ONLY WITH A
  POD THAT HAS EXISTED 45s+ (test procedure: `apps/ai/joplin-export/`
  net-canary pod pattern).
- Joplin CLI 3.7.1 sync: connection errors do NOT fail the sync - it
  logs `[error] FetchError ...` in profile/log.txt, prints "Completed"
  on stdout and finishes with zero items. Verify ingestion via
  `sqlite3 /srv/appdata/joplin-cli/profile/database.sqlite 'select
  count(*) from notes'`, never via the sync's exit status or stdout.
- Joplin sync-target item corruption (2026-10-18, upstream #15757):
  a single malformed item on the target (ours: the WebClipper.png
  resource of the default Welcome note, written by the desktop 3.7.18
  auto-upgrade's delta format) aborts the whole fetch step on OTHER
  clients with `Missing required property: type_`. Fix (maintainer-
  endorsed): on the WORKING client (desktop), search `id:<item-id>` to
  locate the note, delete the note (or attachment) + empty the trash +
  sync - all other clients then sync cleanly. The */5 CronJob stays
  suspended (live patch) until this is done.
- This operator version discovers ServiceMonitor endpoints via v1
  Endpoints only: a selectorless Service with just a hand-written
  EndpointSlice produces NO scrape target (silently - the job appears in
  the Prometheus config but never as a target). Use a pod selector; for
  hostNetwork pods the pod IP is the node IP, so a selector Service gets
  the right endpoints. This is why apps/home/home-assistant/service.yaml
  uses a selector (during a Docker rollback its endpoints vanish - use
  http://nas:8123 then; ha.home.jg-a.com 400s anyway without trusted_proxies).
