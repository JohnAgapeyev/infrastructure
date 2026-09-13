# Operations runbook

Host: `nas` (10.0.0.4). Cluster: single-node k3s, node name `nas`.

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
```

## The 11:30 PM rule

If a pod is crash-looping at bedtime and the fix is not obvious: stop poking
it, `kubectl -n <ns> scale deploy/<x> --replicas=0`, and pick it up tomorrow
with a fresh mind. Self-healing restart loops hide root causes; scaling to 0
quiets the noise and the logs stay available.

## Reboot behaviour

`/srv` is LUKS; if unlock is interactive at boot, k3s waits for it
(`k3s.service` drop-in: `After=srv.mount`, `RequiresMountsFor=/srv`). After
`/srv` is up, all hostPath pods come back on their own. Media stays intact on
the RAID; only k3s runtime (SSD) would be lost on a root disk failure.

## Updating

See [PLAN.md section 12](PLAN.md) - k3s vs Arch packages, Dependabot workflow,
per-app cautions. Summary:

- App image updates: merge Dependabot PR -> `kubectl apply -k apps/<ns>/<app>`
  (Recreate strategy restarts the pod) or `make apply-observability` for the
  chart. Rollback = `git revert` + re-apply.
- k3s: edit `K3S_VERSION` in `bootstrap/k3s/install.sh`, commit,
  `sudo bash bootstrap/k3s/install.sh`. One Kubernetes minor at a time.
- NEVER `pacman -S k3s`/AUR k3s, never install Arch `kubectl` (use `k3s
  kubectl` via the `/usr/local/bin/kubectl` symlink the installer creates).
- Jellyfin minors run one-way DB migrations: tar `/srv/appdata/jellyfin` first
  and confirm Shokofin compatibility.
- qBittorrent/arr never downgrade.

## Backups

- `rclone-backup.timer` (daily) syncs `/srv/Backups` and (Phase 8 on)
  `/srv/appdata` to Backblaze B2 `John-System-Backups`; SQLite DBs are
  snapshotted consistently first (`snapshot-sqlite.sh` via ExecStartPre).
- Disaster recovery: [disaster-recovery.md](disaster-recovery.md).

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
| Shoko | http://shoko.lan | |
| Grafana | http://grafana.lan | |
| Prometheus | http://prometheus.lan | |
| Alertmanager | http://alertmanager.lan | |
| Home Assistant | http://nas:8123 | (Phase 9) |
