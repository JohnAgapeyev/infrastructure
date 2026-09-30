#!/usr/bin/env bash
# -> /usr/local/sbin/networkd-revert.sh  (Phase 9.0 safety net / rollback)
# Undo the dhcpcd -> systemd-networkd switch and reboot.
# Fired automatically by networkd-revert.timer 20 min after systemd starts
# (i.e. after the LUKS unlock) unless the timer was cancelled. Also usable
# manually: sudo /usr/local/sbin/networkd-revert.sh [--no-reboot]
# Nothing here touches the initramfs (mkinitcpio HOOKS, kernel cmdline).
set -u

systemctl disable networkd-revert.timer || true
systemctl disable systemd-networkd.service systemd-networkd-wait-online.service systemd-resolved.service || true
systemctl unmask systemd-network-generator.service || true

if [ -e /etc/resolv.conf.dhcpcd ]; then
    rm -f /etc/resolv.conf
    cp -a /etc/resolv.conf.dhcpcd /etc/resolv.conf
fi

systemctl enable dhcpcd.service

logger -t networkd-revert "reverted systemd-networkd -> dhcpcd"
echo "reverted to dhcpcd (networkd config files left in /etc/systemd/network for inspection)"

if [ "${1:-}" != "--no-reboot" ]; then
    systemctl reboot
fi
