# Phase 9 handoff (resume point)

Updated 2026-09-30, after Phase 9a (Home Assistant) was applied to k3s and
all automated checks passed. A fresh session should read this file first,
then `docs/PLAN.md` section 13 (the authoritative Phase 9 design), then
`docs/operations.md`. Ground rules in PLAN.md section 0 still apply (no
sudo for the agent; every privileged command is handed to John and the
agent waits for confirmation; commit after each phase).

## Where things stand

- Phases 0-8 done and committed. Phase 9 in progress:
- 9.0 (networkd) VERIFIED and committed (`cb5713b`): switch reboot clean,
  `verify-networkd.sh` 25/25 PASS (network-online after DHCPv4+DHCPv6,
  before Docker/k3s; k3s 0 restarts; matter 12/12 nodes). Revert timer
  disabled + inactive. dhcpcd stays installed as the rollback path.
- 9a (Home Assistant) APPLIED and technically verified; commits `295fadc`,
  `ce4be81`, `3569235`, plus the "applied" commit. Cluster state:
  - `home-assistant` Deployment in ns `home`: pod Running/Ready,
    hostNetwork (10.0.0.4), `http://nas:8123` -> 200, `http://ha.lan` ->
    200 via Traefik (selectorless Service + static EndpointSlice,
    `trusted_proxies: [10.42.0.0/16]` appended to the migrated
    configuration.yaml by the migration script; HA `/api/` -> 401 as
    expected; HA logged the real pod-network source IP of a probe curl,
    proving XFF trust works).
  - Integrations identical to pre-migration (17 config entries: backup,
    go2rtc, google_translate, group x6, linkplay, matter, met, mobile_app
    x2, radio_browser, shopping_list, sun). No errors in the startup log
    (the habluetooth NET_ADMIN/NET_RAW ERROR also appeared on every Docker
    start - pre-existing noise, Bluetooth unused).
  - matter integration loaded with no errors; Docker matter-server
    untouched, `health.py` = 12/12 available.
  - `verify-networkd.sh` re-run AFTER the migration: still failures: 0.
- Docker `homeassistant` container: stopped (`exited`), config dir
  `/srv/homeassistant/config` untouched (rsync copy only). Rollback:
  `kubectl -n home scale deploy/home-assistant --replicas=0` then
  `cd /srv/homeassistant && sudo docker compose start homeassistant`
  (use `http://nas:8123` while rolled back - `ha.lan` would 400 because
  the Docker copy has no trusted_proxies).
- PENDING: John's interactive 9a confirmation (see next section). After he
  confirms, commit `phase 9a: verified` and this handoff collapses to the
  9b summary. 9b (Matter) is a LATER DAY per PLAN 13.2.

## First thing to do when resuming

```
kubectl -n home get deploy,pod            # HA still Running/Ready?
docker inspect -f '{{.State.Status}}' homeassistant   # exited (rollback intact)
docker exec -i matter-server python3 - < apps/home/matter-server/health.py
git log --oneline -5
```

| Observation | Meaning / next action |
|---|---|
| HA pod Running, John confirmed the interactive checks | Commit `phase 9a: verified ...` if not done; 9b is next (later day). Follow the 9b summary below. |
| HA pod Running, interactive checks not yet confirmed | Ask John for the list in the next section. |
| HA pod crash-looping / not ready | `kubectl -n home describe pod -l app=home-assistant`, `kubectl -n home logs deploy/home-assistant --tail=100`. Rollback: scale to 0 + `docker compose start homeassistant`, use `http://nas:8123`. |
| HA needs a restart after config edits | `kubectl -n home rollout restart deploy/home-assistant` (HA's own UI restart also works). |

## John's interactive 9a checklist (the only thing pending)

1. `http://ha.lan` (and `http://nas:8123`) load the login page and his
   credentials work.
2. Mobile app reconnects (it may need the internal URL `http://10.0.0.4:8123`
   or `http://nas:8123`; the companion app does not use ha.lan unless told).
3. Matter devices controllable from the HA UI (lovelace toggles).
4. One automation fires (e.g. a sunset/sun-based one; `sun` integration is
   loaded).
5. Optional: Settings -> Devices & Services -> discovery shows devices
   (mDNS/SSDP); Settings -> Logs is clean apart from the habluetooth noise.

## Key facts (do not re-derive)

- HA runs as root (image default, s6 `/init` entrypoint); state
  `/srv/appdata/home-assistant` root:root 11 MB; `.HA_VERSION` 2025.12.4 =
  pinned image tag. In Docker it bound ONLY `/config` + `/etc/localtime`
  (no dbus, no devices) - the k8s Deployment mirrors exactly that plus
  busybox `wait-for-network` init (validated on-node) and
  memory limit 2 Gi (Docker usage was ~505 MiB).
- The init container waits for `ip -4 route show default` and
  `ip -6 addr show dev enp5s0 scope global` (Phase 9.0 root-cause guard).
- `ha.lan` Unbound override exists on OPNsense (A -> 10.0.0.4). Host-local
  `getent` may still serve a cached NXDOMAIN for a while (resolved
  negative caching) - that is cosmetic; clients and pods resolve fine.
- coredns `forward . /etc/resolv.conf` works with the resolved stub because
  kubelet translates `Default`-dnsPolicy pods to real upstreams (verified).
- Boot/host-network/initramfs constraints: PLAN.md 13.0 + operations.md
  "Reboot behaviour" (never touch `ip=`, HOOKS, `.link`, mkinitcpio).
- matter-server (Docker, until 9b): python-matter-server 8.1.2 (final;
  project archived, successor matterjs-server), running digest
  `ghcr.io/matter-js/python-matter-server@sha256:6827e352011e2d8c2bde771e446fcf72acc49150ef66bad978816bac1762aad3`,
  data `/home/john/docker/matter-server/data` (fabric, irreplaceable),
  12 nodes, host network, `restart: unless-stopped`. `john` can run docker
  without sudo. HA reaches it at `ws://localhost:5580/ws`.

## 9b (later day) - summary

Follow PLAN.md 13.2. Pin `8.1.2` only after confirming the tag digest equals
the running digest (`docker buildx imagetools inspect` or registry API).
Same wait-for-network init container; `health.py` via kustomize
`configMapGenerator` mounted at `/probe`; startupProbe exec `python3
/probe/health.py` (period 10 s, failureThreshold 30); livenessProbe period
60 s, timeout 10 s, failureThreshold 5; hostPath `/run/dbus` ro;
PrometheusRule `MatterServerRestarting`
(`increase(kube_pod_container_status_restarts_total{namespace="home",container="matter-server"}[1h]) > 2`)
in `apps/observability/rules/prometheusrule.yaml`. SUDO data move per PLAN
13.2 step 2 (+ extra fabric copy to `/srv/Backups/migration-*/`).
Verification includes full reboot test, `kubectl delete pod`, ~30 s
ethernet pull. Then Docker removal after 2 weeks stable (PLAN 13.2 step 4;
keep dhcpcd installed), and deferred Phase 10 (matterjs-server).

Delete or trim this handoff file once Phase 9 is complete.
