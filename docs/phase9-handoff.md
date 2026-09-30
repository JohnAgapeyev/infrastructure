# Phase 9 handoff (resume point)

Updated 2026-09-30, end of 9b apply/verify: matter-server runs in k3s with
all automated checks green. Remaining: John's device toggle + the reboot
test, then the 2-week Docker-removal gate. A fresh session should read
this file first, then `docs/PLAN.md` section 13, then `docs/operations.md`.
Ground rules in PLAN.md section 0 still apply.

## Where things stand

- 9.0 (networkd) VERIFIED (`cb5711b3`): verify-networkd.sh 25/25, revert
  timer disabled. dhcpcd stays installed as rollback.
- 9a (Home Assistant) VERIFIED (`d39dc5f`): k3s pod Running, http://ha.lan
  + http://nas:8123, 17 integrations, recorder writing.
- 9b (matter-server) APPLIED + verified (commits `5385b9e` + the
  applied/verified commits):
  - Tag `8.1.2` digest-verified == running image (registry check:
    8.1.2 and stable both -> index
    `sha256:6827e352011e2d8c2bde771e446fcf72acc49150ef66bad978816bac1762aad3`).
  - Pod `matter-server` hostNetwork Running/Ready; rollout 32 s;
    `kubectl -n home exec deploy/matter-server -- python3 /probe/health.py`
    -> nodes=12 available=12; all 12 subscriptions succeeded; nodes
    discovered on mDNS.
  - No pre-network startup errors; the `Failed to advertise records ...
    Network is unreachable` CHIP_ERROR lines are the documented normal
    mDNS noise (no-carrier docker0/br-*), NOT failures.
  - HA reconnected over localhost:5580 (established loopback pair
    127.0.0.1:35040<->5580 observed; zero matter errors in HA logs); the
    connection re-established itself after the pod-delete test.
  - Self-heal verified: `kubectl -n home delete pod -l app=matter-server`
    -> new pod Ready in 32 s, 12/12 nodes again, HA reconnected.
  - `verify-networkd.sh` failures: 0 (its matter section now execs into
    the k8s pod when deploy readyReplicas=1).
  - Alert rule applied and LOADED in Prometheus: `MatterServerRestarting`
    (group `home` in media-and-storage-rules); metric
    kube_pod_container_status_restarts_total{namespace="home"} present,
    both pods 0 restarts. (Prometheus rule reload takes ~20-60 s after
    apply - don't be fooled by an immediate "not loaded".)
  - Fabric: `/srv/appdata/matter-server` (root:root, 1.9 MB) + extra copy
    in `/srv/Backups/migration-2026-09-30/matter-fabric-copy-9b/` (root-only
    readable - that dir is chmod 750).
- Docker `homeassistant` + `matter-server` containers: stopped, data dirs
  untouched. Rollback for either:
  `kubectl -n home scale deploy/<name> --replicas=0` + `cd
  /srv/homeassistant && sudo docker compose start <service>`.
- PENDING (John): toggle a Matter device in HA (post-migration sanity),
  then the REBOOT TEST - the final 9b gate.

## The remaining 9b steps

1. John: toggle a Matter device in the HA UI (post-cutover sanity).
2. ### SUDO (user runs) - reboot test, THE point of 9.0/9b:
   `sudo systemctl reboot`; unlock LUKS via tinyssh as usual; SSH in.
3. Agent (after reboot, read-only):
   - `bash bootstrap/host/network/verify-networkd.sh` -> failures: 0
     (covers: network-online after DHCPv4+DHCPv6, no pre-network matter
     errors, nodes available with no manual action, k3s 0 restarts).
   - `kubectl -n home get pods` (both Running, 0 restarts ideally; a
     matter-server restart from liveness during startup is acceptable but
     note it - the startupProbe budget is 5 min).
   - Optionally repeat the ~30 s ethernet pull test (PLAN 13.2 step 3):
     nodes must return on their own; liveness may restart the pod (fine).
4. On success: commit `phase 9b: verified (reboot test)`, trim this
   handoff to the Docker-removal gate:
   - After 2 weeks stable (>= ~2026-10-14) and only if 9a+9b both held:
     PLAN 13.2 step 4 - ### SUDO `docker compose down` in
     /srv/homeassistant; `systemctl disable --now docker docker.socket`;
     archive legacy state to `/srv/Backups/migration-*/legacy-state.tgz`;
     optionally `pacman -Rns docker docker-compose ...` per PLAN. KEEP
     dhcpcd installed (9.0 rollback path).
   - Then delete this handoff file; Phase 10 (matterjs-server) stays
     deferred per PLAN 13.3.
   - If matter-in-k8s turns flaky for > 1 week: roll back to Docker
     (PLAN 13.2 guidance - move Matter out rather than fight it).

## Key facts (do not re-derive)

- matter-server image: ENTRYPOINT `matter-server`, CMD
  `--storage-path /data --paa-root-cert-dir /data/credentials`, runs as
  root; python3+aiohttp in-image (health.py works as a k8s exec probe).
- kustomize namespace gotcha: the Deployment's volume configMap reference
  is only rewritten to the hashed name when the generated ConfigMap and
  Deployment share a namespace -> `namespace: home` is set in
  apps/home/matter-server/kustomization.yaml. Keep it.
- Prometheus rule reload lag after applying rules: up to ~1 min; check
  /api/v1/rules on prometheus.lan (curl --resolve bypasses the host's
  resolved negative cache for *.lan).
- HA rollback uses http://nas:8123 (Docker copy has no trusted_proxies,
  ha.lan would 400). resolved mDNS/LLMNR off; CHIP owns 5353. Both home
  pods are hostNetwork; HA->matter is 127.0.0.1:5580.
- 9.0/9a facts (initramfs constraints, verify script, revert script,
  HA specifics) live in PLAN 13.0-13.2 + operations.md.

Delete this handoff file once Phase 9 is complete.
