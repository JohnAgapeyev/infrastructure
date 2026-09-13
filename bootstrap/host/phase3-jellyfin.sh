#!/usr/bin/env bash
# Phase 3: Jellyfin state migration (SUDO, ~10 min downtime).
# Arch layout -> official image layout (datadir=/config, configdir=/config/config,
# cachedir=/cache, logdir=/config/log):
#   /var/lib/jellyfin/* -> /srv/appdata/jellyfin/
#   /etc/jellyfin/*     -> /srv/appdata/jellyfin/config/
#   /var/cache/jellyfin/* -> /srv/appdata/jellyfin-cache/
# Also: drop Arch's jellyfin.env (webdir/ffmpeg flags; image autodetects ffmpeg);
# pin ServerName=nas (was empty -> would default to pod name); set
# KnownProxies=10.42.0.0/16 (Traefik ingress); enable /metrics (Phase 7).
# encoding.xml needs no edits: HardwareAccelerationType=none, EncoderAppPath unset.
# Run as root: sudo bash bootstrap/host/phase3-jellyfin.sh
set -euo pipefail

systemctl stop jellyfin

rsync -aHAX /var/lib/jellyfin/ /srv/appdata/jellyfin/
mkdir -p /srv/appdata/jellyfin/config && rsync -aHAX /etc/jellyfin/ /srv/appdata/jellyfin/config/
rsync -aHAX /var/cache/jellyfin/ /srv/appdata/jellyfin-cache/

rm -f /srv/appdata/jellyfin/config/jellyfin.env

# ServerName: empty <ServerName /> would default to the pod hostname; pin to `nas`
sed -i 's|<ServerName />|<ServerName>nas</ServerName>|' /srv/appdata/jellyfin/config/system.xml
# KnownProxies: empty -> Traefik (10.42.0.0/16) so client IPs survive ingress
sed -i 's|<KnownProxies />|<KnownProxies><string>10.42.0.0/16</string></KnownProxies>|' /srv/appdata/jellyfin/config/network.xml
# Enable metrics endpoint /metrics (Prometheus, Phase 7)
sed -i 's|<EnableMetrics>false</EnableMetrics>|<EnableMetrics>true</EnableMetrics>|' /srv/appdata/jellyfin/config/system.xml

chown -R 1004:1003 /srv/appdata/jellyfin /srv/appdata/jellyfin-cache

echo "== edited config keys =="
grep -o '<ServerName>[^<]*</ServerName>' /srv/appdata/jellyfin/config/system.xml
grep -o '<EnableMetrics>[^<]*</EnableMetrics>' /srv/appdata/jellyfin/config/system.xml
grep -o '<KnownProxies>.*</KnownProxies>' /srv/appdata/jellyfin/config/network.xml
echo
echo "migration done. next: kubectl apply -k apps/media/jellyfin (run by implementer)"
