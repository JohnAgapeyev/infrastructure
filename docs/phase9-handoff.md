# Phase 9 handoff (resume point)

Updated 2026-09-30, after Phase 9.0 was verified and 9a manifests were
committed. A fresh session should read this file first, then `docs/PLAN.md`
section 13 (the authoritative Phase 9 design), then `docs/operations.md`.
Ground rules in PLAN.md section 0 still apply (no sudo for the agent; every
privileged command is handed to John and the agent waits for confirmation;
commit after each phase).

## Where things stand

- Phases 0-8 done and committed. Phase 9 in progress:
- 9.0 (networkd) VERIFIED and committed (`cb5713b`): switch reboot was clean,
  `verify-networkd.sh` 25/25 PASS (network-online 36.9 s, after DHCPv4
  32.2 s + DHCPv6 35.4 s, before Docker 38.5 s / k3s 45.8 s; k3s 0 restarts;
  matter-server 12/12 nodes, no manual restart). The revert timer is
  disabled + inactive; the safety net never fired. dhcpcd stays installed as
  the rollback path.
- 9a manifests committed (`295fadc`): `apps/home/home-assistant/deployment.yaml`
  (+ `apps/home/home-assistant/kustomization.yaml`, `apps/home/kustomization.yaml`,
  dependabot home group now includes busybox). Server dry-run passed.
- WAITING ON JOHN to run the state migration (see below). Nothing has been
  applied to the cluster yet and the Docker homeassistant container is still
  the live one.

## First thing to do when resuming

Determine which state the host is in (all read-only, no sudo needed):

```
kubectl -n home get deploy,pod                # is the k8s HA up?
docker inspect -f '{{.State.Status}}' homeassistant   # Docker HA stopped?
ls -la /srv/appdata/home-assistant | head     # state copied?
git log --oneline -5                          # which commits exist?
```

| Observation | Meaning / next action |
|---|---|
| Docker HA running, no `/srv/appdata/home-assistant`, no deploy | John has not run the migration. Give him the SUDO block below again, then do the 9a apply + verify. |
| Docker HA exited, `/srv/appdata/home-assistant` exists (12 MB), no deploy | Migration done, apply missing: run `make apply-home` (agent, no sudo), then verify per below. |
| Deploy exists, pod Running/Ready | Apply done; run the verification list; if all good, commit `phase 9a: verified ...` (summarize in operations.md) and update this handoff. 9b is the next phase, on a later day. |
| Deploy exists, pod not ready / crash-looping | `kubectl -n home describe pod -l app=home-assistant`, `kubectl -n home logs deploy/home-assistant --tail=100`. Rollback is always: `kubectl -n home scale deploy/home-assistant --replicas=0 && cd /srv/homeassistant && docker compose start homeassistant`. |

## The 9a steps that remain

0. John (OPNsense UI): Services -> Unbound DNS -> Host Overrides -> add A
   record `ha` in domain `lan` -> `10.0.0.4` (like the existing
   jellyfin/qbit records; `ha.lan` does not resolve yet). Verify with
   `getent hosts ha.lan` after adding.
1. ### SUDO (user runs): `sudo bash bootstrap/host/phase9a-migrate-ha.sh`
   (stops Docker homeassistant; rsyncs `/srv/homeassistant/config/` ->
   `/srv/appdata/home-assistant/`; guard refuses to copy unless the
   container is actually stopped; appends the `http:` trusted_proxies
   block to the COPY only; matter-server keeps running in Docker).
2. Agent: `make apply-home` (no sudo). Watch
   `kubectl -n home get pod -w` and `kubectl -n home logs deploy/home-assistant -f`.
3. Verify (PLAN 13.1 step 3):
   - `http://nas:8123` loads and login works (same credentials; the copy
     includes `.storage` auth).
   - `http://ha.lan` loads (200, not HA's `400 Bad Request` - that 400 is
     the untrusted-XFF rejection and means trusted_proxies is missing).
     Clients should show real IPs in HA, not 10.42.x.
   - All integrations loaded - compare the pre-migration config-entry list
     (taken 2026-09-30, 17 entries):
     `backup go2rtc google_translate group x6 linkplay matter met
     mobile_app x2 radio_browser shopping_list sun`:
     `python3 -c "import json; d=json.load(open('/srv/appdata/home-assistant/.storage/core.config_entries')); from collections import Counter; print(sorted(Counter(e['domain'] for e in d['data']['entries']).items()))"`
   - Matter integration still connected to `ws://localhost:5580/ws`
     (matter-server is still the Docker container, host network, untouched);
     Matter devices controllable from HA.
   - mDNS/SSDP discovery lists devices; mobile app reconnects; an automation
     fires (John confirms).
   - `bash bootstrap/host/network/verify-networkd.sh` still 25/25 (the pod
     DNS checks now also exercise hostNetwork paths indirectly).
4. On success: commit `phase 9a: verified ...` (summary in operations.md
   endpoints table: Home Assistant `http://ha.lan` + legacy
   `http://nas:8123`), leave the Docker homeassistant container stopped for
   >= 1 week as rollback.
5. `ha.lan` ingress details: selectorless Service + static EndpointSlice
   (`apps/home/home-assistant/{service,endpoints,ingress}.yaml`). During a
   Docker rollback the pristine Docker config has no `trusted_proxies`, so
   `http://ha.lan` returns 400 - use `http://nas:8123` while rolled back
   (or re-run the 9a migration script's config block on the Docker copy).
   The whole chain Traefik -> Service -> EndpointSlice -> 10.0.0.4:8123 was
   e2e-verified pre-migration with a throwaway ingress (response came from
   HA itself; the 400 was HA rejecting untrusted X-Forwarded-For).

Rollback at any point: `kubectl -n home scale deploy/home-assistant
--replicas=0` then `cd /srv/homeassistant && sudo docker compose start
homeassistant` (Docker config dir was never modified - rsync copy only).

## Key facts (do not re-derive)

- Docker `homeassistant` container: image `ghcr.io/home-assistant/...:stable`
  (local image == 2025.12.4, `.HA_VERSION` confirms), entrypoint `/init`
  (s6), binds ONLY `/srv/homeassistant/config:/config` and
  `/etc/localtime:ro` (no `/run/dbus`, no devices), `network_mode: host`,
  currently ~505 MiB RSS -> Deployment limits are memory 2Gi.
- `busybox:1.37.0` validated on-node (k3s containerd pulled it; the exact
  init-container `ip -4 route show default` / `ip -6 addr show dev enp5s0
  scope global` busybox syntax was tested in a hostNetwork throwaway pod).
- coredns Corefile has `forward . /etc/resolv.conf` and the node resolv.conf
  is the resolved stub (127.0.0.53) - this WORKS because kubelet translates
  `Default`-dnsPolicy pods' resolv.conf to the real upstreams (verified: a
  Default-dnsPolicy pod sees `nameserver 10.0.0.2`). coredns restarting is
  not a hazard.
- Root cause of the Matter boot failure, host/network facts, initramfs
  constraints (never touch `ip=`, HOOKS, `.link` files, mkinitcpio): all
  recorded in PLAN.md 13.0 and operations.md "Reboot behaviour" - read those
  instead of re-deriving.
- HA/matter containers: `network_mode: host`, `restart: unless-stopped`;
  matter-server: python-matter-server 8.1.2 (final; project archived,
  successor matterjs-server), running digest
  `ghcr.io/matter-js/python-matter-server@sha256:6827e352011e2d8c2bde771e446fcf72acc49150ef66bad978816bac1762aad3`,
  data `/home/john/docker/matter-server/data` (fabric, irreplaceable),
  12 nodes. `john` can run `docker` without sudo.
- Matter health check (Docker phase):
  `docker exec -i matter-server python3 - < apps/home/matter-server/health.py`.

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
Verification includes full reboot test, `kubectl delete pod`, ~30 s ethernet
pull. Then Docker removal after 2 weeks stable (PLAN 13.2 step 4; keep
dhcpcd installed), and deferred Phase 10 (matterjs-server).

Delete or trim this handoff file once Phase 9 is complete.
