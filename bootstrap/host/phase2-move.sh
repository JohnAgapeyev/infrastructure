#!/usr/bin/env bash
# Phase 2: torrent tree move + qBittorrent state migration (SUDO, ~5 min).
# - stops qbittorrent.service (native) - the only downtime
# - SAME-FILESYSTEM GUARD before the mv (must be the /srv ext4, device 64515)
# - mv /srv/misc/torrents -> /srv/Media/Torrents  (instant rename)
# - host convenience symlink back
# - new category dirs (completed/{anime,manual}) + incomplete temp dir
# - rsync config + resume data into /srv/appdata/qbittorrent/qBittorrent
#   (LSIO layout: XDG_CONFIG_HOME and XDG_DATA_HOME both -> /config/qBittorrent)
# - qBittorrent.conf edits (see docs/storage-layout.md capture notes):
#     DefaultSavePath/TempPath -> /srv/Media/Torrents/{completed,incomplete}
#     UseRandomPort=false (Session + legacy General), PortRangeMin=41045
#     WebUI HTTPS off (certs in root-only /home/qbittorrent are NOT migrated)
#   categories.json is NOT touched (paths resolve via compat mount A).
# Run as root: sudo bash bootstrap/host/phase2-move.sh
set -euo pipefail

systemctl stop qbittorrent.service

if [ "$(stat -c %d /srv/misc/torrents)" != "$(stat -c %d /srv/Media)" ]; then
  echo "REFUSING: /srv/misc/torrents and /srv/Media are on different devices" >&2
  exit 1
fi

mv /srv/misc/torrents /srv/Media/Torrents
ln -s /srv/Media/Torrents /srv/misc/torrents

mkdir -p /srv/Media/Torrents/completed/{anime,manual}
chown qbittorrent:media /srv/Media/Torrents/completed/{anime,manual}
chmod 2775 /srv/Media/Torrents/completed/{anime,manual}

mkdir -p /srv/Media/Torrents/incomplete
chown qbittorrent:media /srv/Media/Torrents/incomplete
chmod 2775 /srv/Media/Torrents/incomplete

mkdir -p /srv/appdata/qbittorrent/qBittorrent
rsync -aHAX /home/qbittorrent/.config/qBittorrent/ /srv/appdata/qbittorrent/qBittorrent/
rsync -aHAX /home/qbittorrent/.local/share/qBittorrent/ /srv/appdata/qbittorrent/qBittorrent/
chown -R 1005:1003 /srv/appdata/qbittorrent

CONF=/srv/appdata/qbittorrent/qBittorrent/qBittorrent.conf
sed -i \
  -e 's|^Session\\DefaultSavePath=.*|Session\\DefaultSavePath=/srv/Media/Torrents/completed|' \
  -e 's|^Downloads\\SavePath=.*|Downloads\\SavePath=/srv/Media/Torrents/completed/|' \
  -e 's|^Session\\TempPath=.*|Session\\TempPath=/srv/Media/Torrents/incomplete|' \
  -e 's|^Downloads\\TempPath=.*|Downloads\\TempPath=/srv/Media/Torrents/incomplete|' \
  -e 's|^General\\UseRandomPort=.*|General\\UseRandomPort=false|' \
  -e 's|^Connection\\PortRangeMin=.*|Connection\\PortRangeMin=41045|' \
  -e 's|^WebUI\\HTTPS\\Enabled=.*|WebUI\\HTTPS\\Enabled=false|' \
  "$CONF"
grep -q '^Session\\UseRandomPort=' "$CONF" \
  || sed -i '/^Session\\Port=/a Session\\UseRandomPort=false' "$CONF"

echo
echo "== edited keys in qBittorrent.conf =="
grep -E '^(Session\\(Port|UseRandomPort|DefaultSavePath|TempPath)|Downloads\\(SavePath|TempPath)|General\\UseRandomPort|Connection\\PortRangeMin|WebUI\\HTTPS\\Enabled)=' "$CONF"

echo
echo "move done. next: kubectl apply -k apps/media/qbittorrent (run by implementer)"
