# Phase 9 handoff (final gate: Docker removal)

Updated 2026-09-30, after the 9b reboot test passed. Phase 9's migrations
are DONE and verified; the only remaining step is removing Docker after
the 2-week stability gate. A fresh session should read this file first,
then `docs/PLAN.md` section 13, then `docs/operations.md`. Ground rules in
PLAN.md section 0 still apply.

## Verified state (all commits in `git log`)

- 9.0 networkd (`cb571b`): verify-networkd.sh 25/25; dhcpcd installed but
  disabled (9.0 rollback path - KEEP it installed).
- 9a Home Assistant (`d39dc5f`): k3s pod, http://ha.lan +
  http://nas:8123, 17 integrations, recorder writing; John confirmed
  desktop+mobile login and Matter toggles.
- 9b matter-server (`5385b9e`, `85aff4a` + verified commit): k3s pod,
  12/12 nodes; self-heal (delete pod -> Ready in 32 s); HA reconnected
  over 127.0.0.1:5580; MatterServerRestarting alert loaded in Prometheus.
- REBOOT TEST PASSED (2026-09-30, second networkd boot): verify script
  failures: 0; boot order DHCPv4 42 s -> DHCPv6 45 s -> network-online
  46 s -> k3s 55 s; pods recreated ~10 s later; startup probe waited out
  ConnectionRefused then `nodes=12 available=0`, then Ready with 12/12 -
  no manual action. John confirmed device toggling post-reboot. Expected
  post-reboot cosmetics (see operations.md "Reboot behaviour"): RESTARTS
  shows 1 (container died with the node, exit 255 Unknown - not a crash);
  WARNING "Startup probe failed" events during the first ~2 min.

## The only remaining step: Docker removal (PLAN 13.2 step 4)

Gate: ~2 weeks of stability (until >= 2026-10-14), both home pods healthy.
If matter-in-k8s turns flaky before then, roll back first (below) and
investigate; PLAN guidance: move Matter out rather than fight
IPv6/mDNS in Kubernetes.

### SUDO (user runs), when the gate passes:

```
cd /srv/homeassistant && docker compose down
sudo systemctl disable --now docker docker.socket
# archive legacy state
D=/srv/Backups/migration-<date>
sudo mkdir -p $D && sudo tar -C / -czf $D/legacy-state.tgz \
  home/qbittorrent var/lib/radarr var/lib/sonarr var/lib/jackett \
  var/lib/jellyfin etc/jellyfin srv/homeassistant \
  home/john/docker/matter-server
# optional, John's call (keeps rollback window shorter vs disk space):
sudo pacman -Rns docker docker-compose jackett radarr sonarr-bin \
  qbittorrent-nox jellyfin-server jellyfin-web jellyfin-ffmpeg
```

KEEP `dhcpcd` installed (9.0 rollback path - see operations.md).

After removal: update operations.md (remove Docker rollback pair + the
"rclone-backup Docker" mentions if any), commit `phase 9: docker removed`,
and DELETE this handoff file - Phase 9 is then complete. Phase 10
(matterjs-server) stays deferred per PLAN 13.3 (pair it with the HA
upgrade that requires it; back up the fabric first; health.py WebSocket
get_nodes API is unchanged).

## Rollback pairs (valid until Docker removal)

- HA: `kubectl -n home scale deploy/home-assistant --replicas=0` then
  `cd /srv/homeassistant && sudo docker compose start homeassistant`
  (use http://nas:8123; the Docker copy has no trusted_proxies so ha.lan
  would 400).
- matter-server: `kubectl -n home scale deploy/matter-server
  --replicas=0` then `cd /srv/homeassistant && sudo docker compose start
  matter-server` (fabric dirs were rsync-copied; Docker copy untouched).
- Host networking: `sudo /usr/local/sbin/networkd-revert.sh` (reboots;
  `--no-reboot` to skip) - only if 9.0 itself needs undoing; remove
  `/etc/systemd/network/10-lan.network` first if retrying the switch.

## Health checks (daily driver)

- `kubectl -n home get pods` (both 1/1 Running)
- `kubectl -n home exec deploy/matter-server -- python3 /probe/health.py`
  (nodes=12 available=12)
- `bash bootstrap/host/network/verify-networkd.sh` (failures: 0) -
  matters most after reboots
- Alertmanager UI: MatterServerRestarting should not fire (threshold is
  >2 restarts/h; a single reboot's restart is fine)

Key facts live in operations.md ("Home automation", "Reboot behaviour",
"Known quirks") and PLAN 13 - including the kustomize namespace gotcha
(`apps/home/matter-server/kustomization.yaml` must set namespace: home or
the configMap volume ref is not rewritten) and the Prometheus rule reload
lag (~1 min).

## 9c (active): HA's own metrics via /api/prometheus

Activated 2026-09-30: token Secret `homeassistant-token` (ns home),
`prometheus:` block in the migrated configuration.yaml, ServiceMonitor
`home-assistant` (job label `home-assistant`) scraping
http://10.0.0.4:8123/api/prometheus; target up; 116 entity series.
Grafana "Home" dashboard has HA panels (entities unavailable, activity,
RSS, light brightness). Two lessons recorded in operations.md quirks:
the operator API group is monitoring.coreos.COM (not .io), and the
operator needs a v1 Endpoints object - the home-assistant Service is now
POD-SELECTOR based (hostNetwork pod IP = 10.0.0.4; endpoints.yaml was
deleted; during a Docker rollback ha.lan stops routing - use
http://nas:8123, it 400s anyway without trusted_proxies).

If the token ever needs rotating: create a new long-lived token in the HA
UI, update secrets/homeassistant.env, `kubectl kustomize
--load-restrictor=LoadRestrictionsNone apps/observability/exporters |
kubectl apply -f -`, then `kubectl -n home delete secret
homeassistant-token` is NOT needed (secretGenerator rewrites it; the
ServiceMonitor picks it up after Prometheus reloads).
