# Phase 9 handoff (resume point)

Updated 2026-09-30, mid-9b: matter-server manifests are committed and the
image is pre-pulled; the fabric move is waiting on John's SUDO script. A
fresh session should read this file first, then `docs/PLAN.md` section 13,
then `docs/operations.md`. Ground rules in PLAN.md section 0 still apply.

## Where things stand

- 9.0 (networkd) VERIFIED (`cb5713b`): verify-networkd.sh 25/25, revert
  timer disabled. dhcpcd stays installed as rollback.
- 9a (Home Assistant) VERIFIED (`d39dc5f`): k3s pod Running, http://ha.lan
  + http://nas:8123, 17 integrations, recorder writing. Docker
  `homeassistant` container stopped (rollback until ~2026-10-07).
- 9b (matter-server) IN PROGRESS. Done so far:
  - Digest gate PASSED (2026-09-30, live registry check): tags `8.1.2` and
    `stable` BOTH resolve to index
    `sha256:6827e352011e2d8c2bde771e446fcf72acc49150ef66bad978816bac1762aad3`
    = the running Docker image's RepoDigest. Tag `8.1.2` is byte-identical.
  - `apps/home/matter-server/{deployment.yaml,kustomization.yaml}`:
    hostNetwork + ClusterFirstWithHostNet, Recreate, busybox 1.37.0
    wait-for-network init (same as HA), args `--storage-path /data
    --paa-root-cert-dir /data/credentials` (image ENTRYPOINT
    `matter-server`, CMD overridden explicitly), hostPath
    `/srv/appdata/matter-server` -> `/data`, `/run/dbus` ro,
    `privileged: false`; health.py via configMapGenerator mounted at
    /probe; startupProbe exec python3 /probe/health.py 10 s x 30
    (5 min budget); livenessProbe 60 s / timeout 10 s / 5 failures
    (= 5 min); limits memory 512 Mi (Docker usage: 68 MiB).
  - GOTCHA fixed: kustomize only rewrites the Deployment's volume
    configMap reference to the hashed name when the generated ConfigMap
    and Deployment share a namespace -> `namespace: home` is set in
    apps/home/matter-server/kustomization.yaml (comment explains).
  - PrometheusRule `MatterServerRestarting` added to
    apps/observability/rules/prometheusrule.yaml (home group; verified
    dry-run; NOT applied to the cluster yet - do it after the migration).
  - `bootstrap/host/phase9b-migrate-matter.sh` written (SUDO; stops Docker
    matter-server, rsyncs the fabric to /srv/appdata/matter-server, extra
    copy to /srv/Backups/migration-<date>/matter-fabric-copy-9b/).
  - `bootstrap/host/network/verify-networkd.sh` matter-server section now
    branches: k8s exec if deploy readyReplicas=1, else docker exec.
  - Image pre-pulled into k3s containerd (145 MB, throwaway pod). Image
    digest in containerd = tag 8.1.2 = running image.
  - NOT DONE: the fabric move (John's SUDO), `make apply-home`, the
    observability rules apply, verification (incl. reboot + ethernet-pull
    tests), docs/commit.

## First thing to do when resuming

```
docker inspect -f '{{.State.Status}}' matter-server   # exited => John ran the script
ls /srv/appdata/matter-server                          # fabric copied?
kubectl -n home get deploy,pod                          # HA up, matter absent yet?
kubectl -n home exec deploy/matter-server -- python3 /probe/health.py  # after apply
```

| Observation | Next action |
|---|---|
| Docker matter-server running, no /srv/appdata/matter-server | John has NOT run the script. Re-give the SUDO block below. |
| Docker exited, fabric copied, no deploy | Run `make apply-home`, then the verification list. |
| Deploy exists, pod Running/Ready + health.py 12/12 | Continue verification (HA reconnect, delete-pod test, then John's reboot + ethernet tests), then `kubectl kustomize --load-restrictor=... apps/observability/rules | kubectl apply -f -`, docs, commit. |
| Pod crash-looping / startupProbe failing | `kubectl -n home describe pod -l app=matter-server`, `kubectl -n home logs deploy/matter-server`. Rollback: `kubectl -n home scale deploy/matter-server --replicas=0` + `cd /srv/homeassistant && sudo docker compose start matter-server` (Docker data dir was never modified). |

## The 9b steps that remain

1. ### SUDO (user runs): `sudo bash bootstrap/host/phase9b-migrate-matter.sh`
2. Agent: `make apply-home`; watch
   `kubectl -n home get pod -w` + `kubectl -n home logs deploy/matter-server -f`.
3. Verify:
   - `kubectl -n home exec deploy/matter-server -- python3 /probe/health.py`
     -> nodes=12 available=12 (may take a few minutes; startupProbe budget
     is 5 min).
   - HA Matter integration reconnected: HA UI devices controllable; no
     matter errors in `kubectl -n home logs deploy/home-assistant`.
   - `kubectl -n home delete pod -l app=matter-server` -> pod returns and
     nodes recover (self-heal test).
   - `bash bootstrap/host/network/verify-networkd.sh` -> failures: 0
     (now probes matter-server via kubectl).
4. Apply the alert rule:
   `kubectl kustomize --load-restrictor=LoadRestrictionsNone apps/observability/rules | kubectl apply -f -`
   (same command `make apply-observability` runs for rules, without the
   full helm cycle). Check in Prometheus UI that `MatterServerRestarting`
   is loaded.
5. ### SUDO (user runs, reboot test - THE point of 9.0/9b): `sudo systemctl
   reboot`; unlock LUKS via tinyssh; then wait ~5 min and confirm with
   `bash bootstrap/host/network/verify-networkd.sh` (failures: 0 covers:
   network-online ordering, no pre-network matter errors, nodes available
   without manual action). Optional: ~30 s ethernet pull test.
6. On success: commit `phase 9b: verified ...`, update operations.md
   (matter-server in k3s; health check via kubectl; Docker rollback pair).
   Leave the Docker container stopped >= 2 weeks; then Docker removal per
   PLAN 13.2 step 4 (keep dhcpcd installed). If matter-in-k8s is flaky
   > 1 week: roll back to Docker (PLAN 13.2 guidance).

## Key facts (do not re-derive)

- matter-server image: ENTRYPOINT `matter-server`, default CMD
  `--storage-path /data --paa-root-cert-dir /data/credentials`, runs as
  root; `busybox`/`python3`+aiohttp available (health.py works in-image).
- Fabric: `/home/john/docker/matter-server/data` (root:root 755, 1.5 MB:
  `6722977231884329815.json` + `.backup` (the fabric, 600 KB each),
  `chip_*.ini/json`, `credentials/` (PAA root certs)). Irreplaceable -
  never modify the Docker copy, rsync only.
- Both home pods are hostNetwork: HA reaches matter-server at
  `ws://localhost:5580/ws` - same loopback as in Docker.
- resolved mDNS/LLMNR are OFF; CHIP owns 5353 itself (avahi disabled).
  `Network is unreachable` on mDNS advertise is normal noise.
- kustomize namespace gotcha (configMapGenerator + namespaced Deployment):
  see apps/home/matter-server/kustomization.yaml comment.
- 9a facts (HA rollback pair, trusted_proxies, resolved negative-cache
  quirk, coredns forward-via-stub note) are in the operations.md "Home
  automation" section and PLAN 13.0-13.2.

Delete or trim this handoff file once Phase 9 is complete.
