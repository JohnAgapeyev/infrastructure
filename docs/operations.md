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

Applying changes: `make apply-media` / `apply-home` / `apply-observability`
/ `apply-all`, or `kubectl apply -k apps/<ns>/<app>` (kubeconfig:
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
Switch-boot verification (verify-networkd.sh, 25/25 PASS): network-online
reached 36.9 s into the boot, AFTER DHCPv4 (32.2 s) + DHCPv6 (35.4 s) and
BEFORE Docker (38.5 s) and k3s (45.8 s); k3s booted with 0 restarts and no
"no default routes"; matter-server started clean (12/12 nodes available, no
manual restart); the networkd-revert safety-net timer was cancelled
(disabled + inactive).
Matter health at any time:
`docker exec -i matter-server python3 - < apps/home/matter-server/health.py`.

Home automation (Phase 9): Home Assistant runs in k3s and is VERIFIED
(2026-09-30: desktop+mobile login, Matter toggles, recorder writing to the
migrated DB). It is served at http://ha.lan and http://nas:8123
(`apps/home/home-assistant`, hostNetwork). The Docker `homeassistant`
container is stopped and kept as rollback until ~2026-10-07:
`kubectl -n home scale deploy/home-assistant --replicas=0` then
`cd /srv/homeassistant && docker compose start homeassistant` (use
http://nas:8123 while rolled back; the Docker copy has no
trusted_proxies, so ha.lan would 400). Its config copy is
`/srv/appdata/home-assistant` (Docker original never modified; covered by
the nightly snapshot + rclone jobs). matter-server is STILL the Docker
container (until 9b): health check
`docker exec -i matter-server python3 - < apps/home/matter-server/health.py`.
`ha.lan` needs HA's `http: trusted_proxies: [10.42.0.0/16]` (in the
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
  `/srv/appdata` -> B2 `John-System-Backups/appdata` (rclone `sync`,
  exclusions: prometheus, jellyfin-cache, logs, wal/shm), after
  `snapshot-sqlite.sh` takes consistent SQLite snapshots into
  `/srv/appdata/_snapshots/` (which are then synced too).
- Radarr/Sonarr/Prowlarr additionally write weekly config zips to
  `<app>/Backups/`; qBittorrent BT_backup is copied live; the Matter
  fabric is a tiny json blob; `/srv/Media` is NOT backed up (torrents).
- Check: `systemctl status rclone-backup.service`,
  `rclone lsd Backblaze:John-System-Backups/appdata`.
- Disaster recovery: [disaster-recovery.md](disaster-recovery.md).

## Monitoring & alerting

- Prometheus targets: http://prometheus.lan (all ServiceMonitors picked up
  by design - selector is empty).
- Grafana: http://grafana.lan (admin creds in `secrets/grafana.env`;
  dashboards load automatically from `apps/observability/dashboards/`
  ConfigMaps - edit there, or import in the UI then export back).
- Alertmanager: http://alertmanager.lan - currently ONE null receiver (all
  alerts visible in the UI only; nothing phones anyone). Adding phone/email
  receivers later is a values-only change in
  `apps/observability/kube-prometheus-stack/values.yaml`.
- Custom rules: `apps/observability/rules/prometheusrule.yaml`
  (mdadm failed disks, /srv < 500 GB free, SMART unhealthy,
  MediaServiceDown for 10m).
- Test anytime: `kubectl -n media scale deploy/radarr --replicas=0` for
  ~11 minutes -> MediaServiceDown + TargetDown fire in Alertmanager.

## Service endpoints

| App | URL | Legacy |
|---|---|---|
| qBittorrent | http://qbit.lan | http://nas:8080 |
| Jellyfin | http://jellyfin.lan | http://nas:8096 |
| Prowlarr | http://prowlarr.lan | |
| Radarr | http://radarr.lan | |
| Sonarr | http://sonarr.lan | |
| Bazarr | http://bazarr.lan | |
| Seerr | http://seerr.lan | |
| Shoko | http://shoko.lan/webui/ | |
| Grafana | http://grafana.lan | |
| Prometheus | http://prometheus.lan | |
| Alertmanager | http://alertmanager.lan | |
| Home Assistant | http://ha.lan | http://nas:8123 |

All web UIs require login (qBittorrent: LAN 10.0.0.0/24 bypass + creds for
apps; Radarr/Sonarr/Prowlarr/Bazarr/Shoko/Seerr/Grafana: forms).

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
  for a while (`getent hosts ha.lan` empty). Query OPNsense directly to
  check the record: `nslookup ha.lan 10.0.0.2` from a busybox pod.
- Home Assistant's habluetooth "Missing NET_ADMIN/NET_RAW capabilities"
  ERROR appears on every start, including in Docker - Bluetooth is not in
  use (no bluetooth config entry, no dbus mount); ignore it.
