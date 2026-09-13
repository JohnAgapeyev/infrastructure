#!/usr/bin/env bash
# Phase 0: read-only inventory capture. Prints configs with secret VALUES
# redacted (key names matching Password|PBKDF2|ApiKey|Token|Secret, case
# insensitive). Writes nothing. Run as root:
#
#   sudo bash bootstrap/host/capture-state.sh > /tmp/opencode/capture.txt
#
# No set -e on purpose: capture as much as possible even if an item is missing.
set -uo pipefail

redact() {
  sed -E \
    -e 's/^([^=]*(Password|PBKDF2|ApiKey|Token|Secret)[^=]*=).*/\1REDACTED/I' \
    -e 's#(<[A-Za-z]*(Password|PBKDF2|ApiKey|Token|Secret)[A-Za-z]*>)[^<]*(</)#\1REDACTED\3#I' \
    -e 's/("[^"]*(Password|PBKDF2|ApiKey|Token|Secret|Key)[^"]*"[[:space:]]*:[[:space:]]*")[^"]*(")/\1REDACTED\3/I' \
    -e 's/^([[:space:]]*[A-Za-z0-9_.-]*(Password|PBKDF2|ApiKey|Token|Secret|Key)[A-Za-z0-9_.-]*[[:space:]]*:).*/\1 REDACTED/I'
}

hdr() { printf '\n===== %s =====\n' "$*"; }

hdr "host"
hostname
date -Is

hdr "/etc/crypttab (how nascrypt is unlocked at boot)"
cat /etc/crypttab 2>/dev/null

hdr "ss -tulpn (identify owner of 22822/18555 -> BT port P)"
ss -tulpn

hdr "qBittorrent qBittorrent.conf"
if [ -f /home/qbittorrent/.config/qBittorrent/qBittorrent.conf ]; then
  redact < /home/qbittorrent/.config/qBittorrent/qBittorrent.conf
else
  echo "NOT FOUND at /home/qbittorrent/.config/qBittorrent/qBittorrent.conf"
fi

hdr "qBittorrent data dir"
ls -la /home/qbittorrent/.local/share/qBittorrent/ 2>/dev/null

hdr "qBittorrent categories.json / watched_folders.json (either XDG location)"
for f in \
  /home/qbittorrent/.config/qBittorrent/categories.json \
  /home/qbittorrent/.local/share/qBittorrent/categories.json \
  /home/qbittorrent/.config/qBittorrent/watched_folders.json \
  /home/qbittorrent/.local/share/qBittorrent/watched_folders.json; do
  if [ -f "$f" ]; then
    echo "# $f"
    redact < "$f"
  fi
done

hdr "qBittorrent resume storage"
if [ -f /home/qbittorrent/.local/share/qBittorrent/torrents.db ]; then
  echo "torrents.db EXISTS (SQLite resume storage):"
  ls -la /home/qbittorrent/.local/share/qBittorrent/torrents.db
else
  echo "torrents.db ABSENT"
fi
if [ -d /home/qbittorrent/.local/share/qBittorrent/BT_backup ]; then
  n_fr=$(ls /home/qbittorrent/.local/share/qBittorrent/BT_backup | grep -c fastresume || true)
  n_to=$(ls /home/qbittorrent/.local/share/qBittorrent/BT_backup | grep -c '\.torrent$' || true)
  echo "BT_backup: ${n_fr} fastresume files, ${n_to} .torrent files"
else
  echo "BT_backup dir ABSENT"
fi

hdr "Jellyfin /etc/jellyfin/system.xml"
redact < /etc/jellyfin/system.xml 2>/dev/null
hdr "Jellyfin /etc/jellyfin/network.xml"
redact < /etc/jellyfin/network.xml 2>/dev/null
hdr "Jellyfin /etc/jellyfin/encoding.xml"
redact < /etc/jellyfin/encoding.xml 2>/dev/null

hdr "Jellyfin data dir sizes"
du -sh /var/lib/jellyfin/* 2>/dev/null

hdr "Jellyfin plugins"
ls -la /var/lib/jellyfin/plugins 2>/dev/null

hdr "Jellyfin libraries (root/default/*/options.xml)"
for f in /var/lib/jellyfin/root/default/*/options.xml; do
  if [ -f "$f" ]; then
    echo "# $f"
    redact < "$f"
  fi
done

hdr "Home Assistant configuration.yaml"
redact < /srv/homeassistant/config/configuration.yaml 2>/dev/null

hdr "Home Assistant .HA_VERSION"
cat /srv/homeassistant/config/.HA_VERSION 2>/dev/null

hdr "Home Assistant integration domains (from .storage/core.config_entries)"
grep -o '"domain": *"[^"]*"' /srv/homeassistant/config/.storage/core.config_entries 2>/dev/null | sort -u

hdr "matter-server container"
docker inspect matter-server --format '{{.Config.Image}}' 2>/dev/null
docker inspect matter-server --format 'ImageID: {{.Image}}' 2>/dev/null
docker inspect matter-server --format 'Cmd: {{json .Config.Cmd}}' 2>/dev/null
docker inspect matter-server --format 'Labels: {{json .Config.Labels}}' 2>/dev/null
img=$(docker inspect matter-server --format '{{.Image}}' 2>/dev/null)
[ -n "$img" ] && docker image inspect "$img" --format 'RepoDigests: {{json .RepoDigests}}' 2>/dev/null

hdr "samba smb.conf"
redact < /etc/samba/smb.conf 2>/dev/null

hdr "systemd units (qbittorrent jellyfin radarr sonarr jackett)"
for u in qbittorrent.service jellyfin.service radarr.service sonarr.service jackett.service; do
  echo "--- $u"
  systemctl cat "$u" 2>/dev/null
done

hdr "done"
