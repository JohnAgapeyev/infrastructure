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
  `/srv/appdata/_snapshots/` and `snapshot-postgres.sh` dumps Nextcloud's
  PostgreSQL into `_snapshots/nextcloud/nextcloud.sql.gz` (both then synced).
- Exclusions (see the drop-in for the authoritative list): prometheus,
  jellyfin-cache, logs, wal/shm, the LIVE snapshotted DBs (grafana, shoko,
  jellyfin, seerr, bazarr, home-assistant, hermes state.db, joplin-cli
  profile db, openviking *.db, openclaw *.sqlite), the arr live DBs (their
  weekly zips in `<app>/Backups/` are the restore source - sonarr
  mid-import-waves tore its live DB reads and hard-failed the sync,
  2026-10-13),
  `postgres/**` (the pg_dump is the restore source), the Shokofin VFS
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
| Hermes (AI, OC phase: disabled) | ~~https://hermes.home.jg-a.com~~ | |
| OpenViking (AI, OC phase: disabled) | ~~https://openviking.home.jg-a.com~~ (Web Studio at `/studio`) | |
| OpenClaw (AI) | https://openclaw.home.jg-a.com (Control UI; gateway-token auth) | |

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


## AI ops (OpenClaw + joplin-export; OC phase - Hermes/OpenViking disabled)

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

### Go-live order (repo work is done; these are the owner steps)

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

### First live-run VERIFY items

- VERIFIED 2026-10-18 (joplin CLI, unchanged): one-shot commands are
  non-interactive by default (NO `--non-interactive` flag exists); sync
  target 6 = WebDAV; the FIRST `joplin sync` downloads the whole vault and
  can exceed the 300s job deadline (bootstrap once with
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

### End-to-end checks

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

- Dependabot "ai" group (openclaw + the disabled-but-listed openviking/hermes
  images) -> merge PR -> `make apply-ai` (Recreate restarts pods). The image
  entrypoint runs `openclaw doctor --fix` on start: agent DB schema
  migrations happen under maintenance ownership with pre-migration `.bak`
  copies kept in the state dir - KEEP those with the pre-upgrade backup
  (disaster-recovery.md). Upstream releases are date-versioned and frequent
  (`2026.x.y`); if Dependabot PR volume is annoying, add ignore rules.
  Rollback = `git revert` + `make apply-ai` + restore any `.bak`/snapshot the
  doctor took (see upstream "rollback" - the DB state must match the image).
- Startup exit code 78 = "refused to migrate unsafe state" (source identity
  conflicts, another writer, unwritable state) - do NOT delete lock files;
  see the upstream health/docs flow instead.
- npm pin inside `apps/ai/joplin-export/run.sh` (joplin 3.7.1) is manual,
  like K3S_VERSION; bump the joplin CLI in step with the desktop client's
  Joplin version.

### Revert procedure (to Hermes + OpenViking)

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
  lesson): the UI probe runs an embedded agent session with a tiny
  generation budget; with `thinking=medium` (the onboard default) the
  reasoning model burns the whole probe budget on reasoning tokens ->
  EMPTY content -> the probe reports "The connection check failed" even
  though the API call returned HTTP 200 (visible in logs as
  `[model-fetch] response ... status=200 contentType=text/event-stream`
  right next to the failed probes). Fix: `openclaw config set
  agents.defaults.thinkingDefault off`. Thinking can still be enabled
  per-session in the Control UI. If it recurs after re-enabling
  thinking, the probe failure is cosmetic - trust a real chat turn.
  (The CLI probe `openclaw models status --probe` refuses to run while
  the gateway owns the state dir - by design; verify from the UI.)
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
- Sync-lock contention with the desktop client: the job is Forbid + 300s
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
