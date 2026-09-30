#!/usr/bin/env bash
# Phase 9.0 post-reboot verification. Read-only; run as john (no sudo):
#   bash bootstrap/host/network/verify-networkd.sh
# Prints PASS/FAIL per check; exit code = number of failures.
set -u
cd "$(dirname "$(readlink -f "$0")")/../../.."

fails=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; fails=$((fails + 1)); }
check() { local desc=$1; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

echo "== units =="
check "systemd-networkd active"            systemctl is-active --quiet systemd-networkd
check "systemd-resolved active"            systemctl is-active --quiet systemd-resolved
check "wait-online succeeded"              bash -c 'systemctl is-active --quiet systemd-networkd-wait-online && [ "$(systemctl show -P Result systemd-networkd-wait-online)" = success ]'
check "dhcpcd not running"                 bash -c '! pgrep -x dhcpcd'
check "network-generator masked, /run/systemd/network empty" \
    bash -c '[ "$(systemctl is-enabled systemd-network-generator 2>&1)" = masked ] && [ -z "$(ls -A /run/systemd/network 2>/dev/null)" ]'

echo "== addresses / routes / identity =="
check "IPv4 10.0.0.4/16 on enp5s0"         bash -c 'ip -4 -o addr show dev enp5s0 | grep -q " 10.0.0.4/16 "'
check "DHCPv6 ::2000/128 on enp5s0"        bash -c 'ip -6 -o addr show dev enp5s0 scope global | grep -q "::2000/128"'
check "IPv4 default via 10.0.0.2"          bash -c 'ip -4 route show default | grep -q "via 10.0.0.2 dev enp5s0"'
check "IPv6 default route on enp5s0"       bash -c 'ip -6 route show default | grep -q "dev enp5s0"'
check "enp5s0 is routable"                 bash -c 'networkctl status enp5s0 --no-pager | grep -qE "State: routable"'
check "only enp5s0 managed by networkd"    bash -c '[ "$(networkctl list --no-legend | awk "\$5 != \"unmanaged\" && \$2 != \"lo\"" | awk "{print \$2}")" = enp5s0 ]'
networkctl status enp5s0 --no-pager 2>/dev/null | grep -E 'DUID|Client ID|IAID' | sed 's/^/      /'

echo "== DNS =="
check "resolv.conf -> resolved stub"       bash -c 'readlink /etc/resolv.conf | grep -q "run/systemd/resolve/stub-resolv.conf"'
check "enp5s0 DNS server 10.0.0.2"         bash -c 'resolvectl dns enp5s0 | grep -q 10.0.0.2'
check "search domain lan"                  bash -c 'resolvectl domain enp5s0 | grep -qw lan'
check "resolved mDNS/LLMNR off"            bash -c 'resolvectl status | grep -E "^ *Protocols:" | head -1 | grep -q -- "-LLMNR -mDNS"'
check "host: jellyfin.lan -> 10.0.0.4"     bash -c 'getent hosts jellyfin.lan | grep -q "^10.0.0.4 "'
check "host: github.com resolves"          getent hosts github.com
check "pod: github.com resolves"           kubectl -n media exec deploy/jellyfin -- getent hosts github.com
check "pod: cluster DNS works"             kubectl -n media exec deploy/jellyfin -- getent hosts radarr.media.svc.cluster.local

echo "== boot ordering =="
J=$(journalctl -b -o short-monotonic --no-pager 2>/dev/null)
online=$(grep -n 'Reached target .*Network is Online' <<<"$J" | head -1 | cut -d: -f1)
v4=$(grep -n 'enp5s0: DHCPv4 address' <<<"$J" | head -1 | cut -d: -f1)
v6=$(grep -n 'enp5s0: DHCPv6 address' <<<"$J" | head -1 | cut -d: -f1)
check "network-online after DHCPv4+DHCPv6" bash -c "[ -n '$online' ] && [ -n '$v4' ] && [ -n '$v6' ] && [ $online -gt $v4 ] && [ $online -gt $v6 ]"
grep -E 'Reached target .*Network is Online|enp5s0: (DHCPv4|DHCPv6) address|Started (Docker|Lightweight Kubernetes)' <<<"$J" | head -8 | sed 's/^/      /'
check "k3s did not crash-restart at boot"  test "$(systemctl show -P NRestarts k3s)" = 0
check "no 'no default routes' from k3s"    bash -c '! journalctl -b -u k3s --no-pager | grep -q "no default routes found"'

echo "== matter-server (Docker) =="
# "Network is unreachable" on mDNS advertise is normal noise (no-carrier
# docker0/br-* interfaces); these two only appear when started pre-network.
check "no pre-network startup errors since start" \
    bash -c '! docker logs --since "$(docker inspect -f "{{.State.StartedAt}}" matter-server)" matter-server 2>&1 | grep -qE "Temporary failure in name resolution|Cannot assign requested address"'
ok=""
for _ in $(seq 1 20); do   # nodes can take a minute or two to come up after start
    if out=$(docker exec -i matter-server python3 - < apps/home/matter-server/health.py 2>&1); then ok=1; break; fi
    sleep 15
done
echo "      $out"
if [ -n "$ok" ] && ! grep -q 'available=0' <<<"$out"; then pass "Matter nodes available without a manual restart"; else fail "Matter nodes available without a manual restart"; fi

echo "== safety net =="
if systemctl is-active --quiet networkd-revert.timer; then
    echo "WARN  networkd-revert.timer is STILL ARMED: sudo systemctl disable --now networkd-revert.timer"
else
    pass "networkd-revert.timer cancelled"
fi

echo
echo "failures: $fails"
exit "$fails"
