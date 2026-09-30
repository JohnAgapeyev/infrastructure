# Phase 9 handoff (resume point)

Updated 2026-09-30, after Phase 9a (Home Assistant) was VERIFIED. A fresh
session should read this file first, then `docs/PLAN.md` section 13 (the
authoritative Phase 9 design), then `docs/operations.md`. Ground rules in
PLAN.md section 0 still apply (no sudo for the agent; every privileged
command is handed to John and the agent waits for confirmation; commit
after each phase).

## Where things stand

- Phases 0-8 done and committed. Phase 9:
- 9.0 (networkd) VERIFIED (`cb5713b`): switch reboot clean,
  `verify-networkd.sh` 25/25 PASS; network-online after DHCPv4+DHCPv6,
  before Docker/k3s; k3s 0 restarts; matter 12/12 nodes. Revert timer
  disabled + inactive. dhcpcd stays installed as the rollback path.
- 9a (Home Assistant) VERIFIED 2026-09-30 (John confirmed: desktop +
  mobile login, Matter devices toggle in UI; no automations exist to
  test - N/A). Automated checks: pod Running/Ready 0 restarts;
  `http://ha.lan` 200 via Traefik (trusted_proxies works - HA logs real
  client IPs); `http://nas:8123` 200; 17 config entries identical to
  pre-migration; recorder writing to the migrated DB (WAL active, events
  from post-migration logins/toggles present); `verify-networkd.sh`
  re-run post-migration: failures: 0. `snapshot-sqlite.sh` + rclone
  drop-in already cover `/srv/appdata/home-assistant` (written
  anticipating 9a).
- Docker `homeassistant` container: stopped, config dir untouched. ROLLBACK
  (available until ~2026-10-07, then remove with the Docker cleanup):
  `kubectl -n home scale deploy/home-assistant --replicas=0` then
  `cd /srv/homeassistant && sudo docker compose start homeassistant`;
  use `http://nas:8123` while rolled back (`ha.lan` would 400 - the Docker
  copy has no trusted_proxies).
- NEXT: 9b (Matter Server) on a LATER DAY per PLAN 13.2. Not started; no
  manifests exist yet (`apps/home/matter-server/` currently holds only
  health.py). matter-server is still the live Docker container.

## First thing to do when resuming (9b day)

```
kubectl -n home get deploy,pod            # HA still Running/Ready?
docker exec -i matter-server python3 - < apps/home/matter-server/health.py
docker inspect matter-server --format '{{.Image}} {{.State.Status}}'
git log --oneline -3
```

If HA is down: `kubectl -n home logs deploy/home-assistant --tail=100`,
rollback above. Otherwise start 9b.

## 9b plan (authoritative version: PLAN.md 13.2)

1. Confirm the `ghcr.io/matter-js/python-matter-server:8.1.2` tag digest
   equals the running digest `sha256:6827e352011e2d8c2bde771e446fcf72acc49150ef66bad978816bac1762aad3`
   (`docker buildx imagetools inspect` or registry API) BEFORE writing the
   tag into the manifest. 8.1.2 is the final release (project archived).
2. `apps/home/matter-server/deployment.yaml`: `hostNetwork: true`,
   `dnsPolicy: ClusterFirstWithHostNet`, replicas 1 Recreate, args
   `--storage-path /data --paa-root-cert-dir /data/credentials`, hostPath
   `/srv/appdata/matter-server` -> `/data`, hostPath `/run/dbus` -> `/run/dbus`
   ro, `privileged: false` (AppArmor not active on Arch; compose
   `apparmor:unconfined` needs no equivalent). Same busybox wait-for-network
   init container as HA (`busybox:1.37.0`, validated on-node 2026-09-30).
3. `health.py` via kustomize `configMapGenerator` mounted at `/probe`;
   startupProbe exec `python3 /probe/health.py` period 10 s
   failureThreshold 30; livenessProbe same command period 60 s timeout 10 s
   failureThreshold 5. (Trade-off: if every device is genuinely offline the
   pod restarts with backoff - harmless, restart is the recovery action.)
4. PrometheusRule `MatterServerRestarting` in
   `apps/observability/rules/prometheusrule.yaml`:
   `increase(kube_pod_container_status_restarts_total{namespace="home",container="matter-server"}[1h]) > 2`.
   Then `make apply-observability`.
5. ### SUDO (John): `docker compose stop matter-server` in
   `/srv/homeassistant`; `rsync -aHAX /home/john/docker/matter-server/data/
   /srv/appdata/matter-server/` (1.5 MB; the fabric is irreplaceable -
   extra copy to `/srv/Backups/migration-*/matter-fabric-copy-9b`).
6. Agent: `make apply-home`; verify: HA Matter integration reconnects,
   every device controllable, `kubectl -n home exec deploy/matter-server --
   python3 /probe/health.py` all nodes; FULL REBOOT TEST (no manual action,
   nodes available < 5 min after boot - this is the whole point of 9.0);
   `kubectl -n home delete pod -l app=matter-server` recovers; ~30 s
   ethernet pull recovers.
7. After 2 weeks stable (HA + matter): Docker removal per PLAN 13.2 step 4
   (### SUDO; keep dhcpcd installed as 9.0 rollback; archive legacy state
   to `/srv/Backups/migration-*/legacy-state.tgz`).
8. If matter-in-k8s stays flaky > 1 week: roll back to Docker (ChatGPT
   session guidance: move Matter out rather than fight IPv6/mDNS in
   Kubernetes).

## Key facts (do not re-derive)

- HA in k8s: `ghcr.io/home-assistant/home-assistant:2025.12.4`, hostNetwork,
  root (s6 `/init`), state `/srv/appdata/home-assistant` (root:root);
  bluetooth NET_ADMIN/NET_RAW ERROR in its log is pre-existing Docker-era
  noise, ignore. `ha.lan` = selectorless Service + static EndpointSlice +
  Ingress; needs HA `http: trusted_proxies: [10.42.0.0/16]` (in the
  migrated configuration.yaml). Unbound `ha` -> 10.0.0.4 exists.
- systemd-resolved caches negative answers: a fresh Unbound record may not
  resolve host-locally for a while; query `nslookup ha.lan 10.0.0.2` from
  a busybox pod (dnsPolicy Default) to check the record itself.
- coredns `forward . /etc/resolv.conf` works with the resolved stub because
  kubelet translates Default-dnsPolicy pods to real upstreams (verified).
- Init container network wait: `ip -4 route show default` +
  `ip -6 addr show dev enp5s0 scope global` (Phase 9.0 root-cause guard).
- Boot/host-network/initramfs constraints: PLAN.md 13.0 + operations.md
  "Reboot behaviour" (never touch `ip=`, HOOKS, `.link`, mkinitcpio).
- matter-server (Docker, until 9b): python-matter-server 8.1.2 (final;
  successor matterjs-server = deferred Phase 10), running digest above,
  data `/home/john/docker/matter-server/data` (fabric), 12 nodes, host
  network, `restart: unless-stopped`, HA reaches it at
  `ws://localhost:5580/ws`. `john` can run docker without sudo. The
  compose mounts `/run/dbus` ro (Bluetooth via dbus, per its comment) and
  sets `apparmor:unconfined` for the same reason; Bluetooth is not in use
  (no bluetooth-adapter arg, no HA bluetooth config entry), but keep the
  dbus mount in 9b exactly as PLAN 13.2 specifies - costless parity with
  the container. mDNS needs no dbus: resolved mDNS/LLMNR are off and CHIP
  owns 5353 itself.

Delete or trim this handoff file once Phase 9 is complete.
