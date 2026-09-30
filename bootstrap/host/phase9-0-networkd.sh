#!/usr/bin/env bash
# Phase 9.0: switch real-root networking dhcpcd -> systemd-networkd (+resolved)
# so network-online.target really means "IPv4 + IPv6 routable" and docker/k3s
# (matter-server) no longer start before the network exists.
#
# Does NOT touch the initramfs: mkinitcpio HOOKS (netconf tinyssh encryptssh),
# the kernel `ip=` parameter and /etc/mkinitcpio.conf are only checked, never
# modified; no mkinitcpio rebuild. Nothing changes in the running network
# either: dhcpcd keeps running until the reboot you trigger afterwards.
#
# Run as root: sudo bash bootstrap/host/phase9-0-networkd.sh
set -euo pipefail

D="$(dirname "$(readlink -f "$0")")/network"
MAC=d4:5d:64:ba:44:dd
DUID=00:01:00:01:2c:56:10:20:d4:5d:64:ba:44:dd

die() { echo "ABORT: $*" >&2; exit 1; }

echo "== preconditions (no changes made yet) =="
[ "$(cat /sys/class/net/enp5s0/address)" = "$MAC" ] || die "enp5s0 MAC is not $MAC"
grep -q 'ip=:::::eth0:dhcp' /proc/cmdline || die "kernel ip= parameter differs from expected"
grep -qE '^HOOKS=.*netconf tinyssh encryptssh' /etc/mkinitcpio.conf || die "mkinitcpio HOOKS differ from expected"
[ "$(tr -d '[:space:]' < /var/lib/dhcpcd/duid)" = "$DUID" ] || die "/var/lib/dhcpcd/duid is not $DUID (update 10-lan.network)"
[ -f /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ] || die "/etc/resolv.conf is not the dhcpcd-written regular file"
[ -z "$(ls -A /etc/systemd/network 2>/dev/null)" ] || die "/etc/systemd/network is not empty"
systemctl is-enabled --quiet dhcpcd.service || die "dhcpcd.service is not enabled (unexpected state)"
echo "ok"

echo "== install config =="
install -D -m 0644 "$D/10-lan.network"          /etc/systemd/network/10-lan.network
install -D -m 0644 "$D/networkd-foreign.conf"   /etc/systemd/networkd.conf.d/10-foreign.conf
install -D -m 0644 "$D/resolved-lan.conf"       /etc/systemd/resolved.conf.d/10-lan.conf
install -D -m 0755 "$D/networkd-revert.sh"      /usr/local/sbin/networkd-revert.sh
install -D -m 0644 "$D/networkd-revert.service" /etc/systemd/system/networkd-revert.service
install -D -m 0644 "$D/networkd-revert.timer"   /etc/systemd/system/networkd-revert.timer
cp -a /etc/resolv.conf /etc/resolv.conf.dhcpcd
systemctl daemon-reload

echo "== switch units for next boot =="
# The generator would turn the initramfs-only `ip=:::::eth0:dhcp` into a
# second networkd config; masking it affects the real root only.
systemctl mask systemd-network-generator.service
systemctl enable systemd-networkd.service systemd-networkd-wait-online.service systemd-resolved.service
systemctl disable dhcpcd.service
# enable (not --now): the timer arms on the next boot only
systemctl enable networkd-revert.timer

# Last step: DNS via resolved's stub. Name resolution on this boot is broken
# from here until the reboot (resolved is not running yet) - reboot promptly.
ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo
echo "== state for next boot =="
for u in dhcpcd systemd-networkd systemd-networkd-wait-online systemd-resolved systemd-network-generator networkd-revert.timer; do
    printf '%-32s %s\n' "$u" "$(systemctl is-enabled "$u" 2>&1)"
done
echo "resolv.conf -> $(readlink /etc/resolv.conf)"
echo
echo "Done. Now reboot: sudo systemctl reboot"
echo "Safety net: 20 min after systemd starts (post-unlock), the system reverts"
echo "to dhcpcd and reboots unless you run: sudo systemctl disable --now networkd-revert.timer"
