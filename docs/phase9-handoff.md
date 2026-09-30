# Phase 9 handoff (resume point)

Written 2026-09-30 before the Phase 9.0 reboot. A fresh session should read
this file first, then `docs/PLAN.md` section 13 (the authoritative Phase 9
design), then `docs/operations.md`. Ground rules in PLAN.md section 0 still
apply (no sudo for the agent; every privileged command is handed to John and
the agent waits for confirmation; commit after each phase).

## Where things stand

- Phases 0-8 are done and committed (see `git log`). Phase 9 is in progress.
- Commit `2209eb4` ("phase 9.0 prep") added the 9.0 files, rewrote PLAN.md
  section 13, and added a host-networking note to operations.md.
- 9.0 has NOT been verified yet at the time of writing. John was about to:
  1. `sudo bash bootstrap/host/phase9-0-networkd.sh`
  2. `sudo systemctl reboot`, unlock LUKS via tinyssh as usual
  3. SSH in, `sudo systemctl disable --now networkd-revert.timer`
  4. `bash bootstrap/host/network/verify-networkd.sh` and paste the output

## First thing to do when resuming

Determine which state the host is in (all read-only, no sudo needed):

```
systemctl is-active systemd-networkd systemd-resolved; systemctl is-enabled dhcpcd
systemctl is-active networkd-revert.timer
journalctl -t networkd-revert --no-pager      # present => the safety net fired
bash bootstrap/host/network/verify-networkd.sh
```

| Observation | Meaning / next action |
|---|---|
| networkd active, dhcpcd disabled, verify `failures: 0` | 9.0 succeeded. Make sure the revert timer is inactive (if still armed, ask John to run `sudo systemctl disable --now networkd-revert.timer` IMMEDIATELY - it reboots the box 20 min after systemd start). Commit `phase 9.0: ...` with verify results summarized in operations.md, then start 9a. |
| networkd active but some FAILs | Diagnose the specific check. Known soft spots: the boot-ordering check greps networkd's `enp5s0: DHCPv4 address` / `enp5s0: DHCPv6 address` log wording (if the wording differs, fix the script, not the system); pod DNS may need `kubectl -n kube-system rollout restart deploy/coredns`. |
| IP is not 10.0.0.4 or no `::2000` | OPNsense did not accept the carried-over DUID/IAID. Compare `networkctl status enp5s0` DUID/Client ID with `00:01:00:01:2c:56:10:20:d4:5d:64:ba:44:dd` / IAID `0x64ba44dd`. Fix `bootstrap/host/network/10-lan.network`, or have John update the OPNsense static mapping. |
| dhcpcd enabled again, `networkd-revert` in journal | The safety net fired (John could not reach the box or forgot to cancel). Ask John what happened, then inspect the failed boot: `journalctl -b -1 -u systemd-networkd -u systemd-networkd-wait-online -u systemd-resolved`. Config files were left in `/etc/systemd/network` etc. To retry: the switch script's precondition "/etc/resolv.conf is regular file" holds again after revert, but "/etc/systemd/network is empty" does NOT - John must `sudo rm /etc/systemd/network/10-lan.network` first (or adjust the script). |
| Script never run (dhcpcd active, no networkd) | John has not done 9.0 yet; give him the steps above again. |

## Key facts gathered this session (do not re-derive)

Root cause of "all Matter lights unavailable after reboot":
- `dhcpcd.service` = `dhcpcd -q -B`, nothing implements
  `network-online.target` -> it is reached before the NIC has carrier.
- initramfs `netconf` cleanup hook (`/usr/lib/initcpio/hooks/netconf`)
  flushes + downs `eth0` before switch_root, so real root starts link-down
  (~3 s renegotiation).
- Docker started matter-server ~0.4 s before carrier; its startup logged
  `Temporary failure in name resolution` and `Cannot assign requested address`;
  CHIP binds mDNS once, so nodes never came back (12 nodes, 0 available
  after 3 h). HA stayed connected, port 5580 listened -> tcp probes are
  useless. `docker restart matter-server` fixed it (12/12).
- `Network is unreachable` on mDNS advertise is NORMAL noise even on a healthy
  start (no-carrier docker0/br-*); don't treat it as a failure signal.
- k3s hit the same race (`no default routes found`, restarted by systemd).

Host / network:
- NIC `enp5s0` (kernel name `eth0` in initramfs), MAC `d4:5d:64:ba:44:dd`,
  r8169. IPv4 10.0.0.4/16 gw 10.0.0.2 (OPNsense, DNS, domain `lan`). IPv6
  Telus prefix `2001:569:77f3:3000::/64`, DHCPv6 address `::2000/128`.
- dhcpcd DUID `00:01:00:01:2c:56:10:20:d4:5d:64:ba:44:dd` (LLT), IAID
  `64:ba:44:dd` = 1689928925. `/etc/dhcpcd.conf` had `slaac private`,
  `noipv4ll`, `persistent`, `duid`.
- Initramfs (must never be disturbed - tinyssh remote LUKS unlock):
  mkinitcpio busybox, `HOOKS=(base udev autodetect keyboard keymap modconf
  block mdadm_udev lvm2 netconf tinyssh encryptssh filesystems fsck)`, kernel
  cmdline `ip=:::::eth0:dhcp cryptdevice=UUID=0e551b6e-...:RootVG`.
  Do not switch to the systemd initramfs, do not change `ip=`, do not add
  `.link` files, do not rebuild mkinitcpio for Phase 9.
- `systemd-network-generator.service` (pulled in via networkd's `Also=`)
  would translate the initramfs-only `ip=` into a networkd config -> the
  switch script masks it; revert unmasks it.
- avahi installed but disabled; 5353 is owned by HA + matter-server (host
  network) -> resolved has `MulticastDNS=no`, `LLMNR=no`.
- Arch default `/usr/lib/systemd/network/*.network` only match nspawn/VM
  names (ve-*, vb-*, vz-*, vt-*, ns-*, host0) -> k3s `veth*`, `cni0`,
  `flannel.1` and Docker `docker0`/`br-*` stay unmanaged.
- systemd 262, dhcpcd 10.5.2, mkinitcpio 42.1. NetworkManager not installed
  (evaluated and rejected; dhcpcd@ template also rejected - see PLAN 13.0).

Home Assistant / Matter (still in Docker, `/srv/homeassistant/docker-compose.yaml`,
both `network_mode: host`, `restart: unless-stopped`, images on `:stable`):
- HA `.HA_VERSION` = `2025.12.4`; config `/srv/homeassistant/config`.
- matter-server: python-matter-server `8.1.2` (final release; project
  archived, successor `matterjs-server`), CHIP SDK 2025.7.0, schema 11,
  running image digest
  `ghcr.io/matter-js/python-matter-server@sha256:6827e352011e2d8c2bde771e446fcf72acc49150ef66bad978816bac1762aad3`.
  Data `/home/john/docker/matter-server/data` (fabric, irreplaceable), 12 nodes.
- `john` can run `docker` without sudo.
- Health check: `docker exec -i matter-server python3 - < apps/home/matter-server/health.py`
  (exit 0 = no nodes or >= 1 available; prints `nodes=N available=M`).

## Files added for Phase 9 so far

- `bootstrap/host/phase9-0-networkd.sh` - SUDO switch script (preconditions,
  install, mask generator, enable networkd/wait-online/resolved, disable
  dhcpcd, arm revert timer, resolv.conf -> stub; backup `/etc/resolv.conf.dhcpcd`).
- `bootstrap/host/network/10-lan.network`, `networkd-foreign.conf`,
  `resolved-lan.conf` - installed configs (destinations in file headers).
- `bootstrap/host/network/networkd-revert.{sh,service,timer}` - safety net;
  script installed to `/usr/local/sbin/networkd-revert.sh`.
- `bootstrap/host/network/verify-networkd.sh` - read-only post-reboot checks.
- `apps/home/matter-server/health.py` - semantic Matter health probe.
- NOTE: `apps/home/` has no `kustomization.yaml` yet; `make apply-home`
  will fail until 9a adds `apps/home/kustomization.yaml` (+ home-assistant).

## Remaining work after 9.0 is verified

Follow PLAN.md sections 13.1-13.3. Summary of what to build:

9a Home Assistant (`apps/home/home-assistant/`, plus `apps/home/kustomization.yaml`):
- Deployment ns `home`, image `ghcr.io/home-assistant/home-assistant:2025.12.4`,
  `hostNetwork: true`, `dnsPolicy: ClusterFirstWithHostNet`, replicas 1,
  Recreate, hostPath `/srv/appdata/home-assistant` -> `/config`
  (directory must be created by John: `mkdir` + ownership root, since HA runs
  as root like in Docker), `/etc/localtime` ro, env TZ America/Vancouver,
  `privileged: false`.
- Init container (pinned busybox, e.g. `busybox:1.37.0` - verify tag exists)
  looping until `ip -4 route show default` and
  `ip -6 addr show dev enp5s0 scope global` are non-empty.
- Probe `httpGet / 8123`, `initialDelaySeconds: 60`.
- Update `.github/dependabot.yml` `home` group if needed; follow the style
  of `apps/media/jellyfin/`.
- SUDO for John: `cd /srv/homeassistant && docker compose stop homeassistant`;
  `rsync -aHAX /srv/homeassistant/config/ /srv/appdata/home-assistant/`;
  then agent runs `make apply-home`. Verify per PLAN 13.1 step 3; the Matter
  integration must still reach `ws://localhost:5580/ws` (Docker matter-server).

9b Matter Server (a later day, `apps/home/matter-server/`):
- Pin `8.1.2` after confirming the tag's digest equals the running digest
  above (e.g. `docker buildx imagetools inspect` or registry API).
- Same init container; ConfigMap from `health.py` (kustomize
  `configMapGenerator`) mounted at `/probe`; startupProbe exec
  `python3 /probe/health.py` period 10 s failureThreshold 30; livenessProbe
  period 60 s timeout 10 s failureThreshold 5.
- PrometheusRule `MatterServerRestarting` in
  `apps/observability/rules/prometheusrule.yaml`:
  `increase(kube_pod_container_status_restarts_total{namespace="home",container="matter-server"}[1h]) > 2`.
- SUDO data move per PLAN 13.2 step 2 (+ extra fabric copy to
  `/srv/Backups/migration-*/`). Verification includes a full reboot test,
  `kubectl delete pod`, and a ~30 s ethernet pull.

Then Docker removal after 2 weeks stable (PLAN 13.2 step 4; keep dhcpcd
installed as 9.0 rollback), and deferred Phase 10 (matterjs-server).

Delete or trim this handoff file once Phase 9 is complete.
