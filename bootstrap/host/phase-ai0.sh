#!/usr/bin/env bash
# AI-0 host prep (run with sudo). Creates the four state dirs for the AI
# namespace. Ownership notes:
# - hermes: image runtime user is UID 10000; its entrypoint chowns the
#   volume on first boot anyway - pre-creating with the right owner keeps
#   /srv/appdata consistent (grafana-472 / nextcloud-33 precedent)
# - openviking: image has no USER directive -> runs as root
# - joplin-cli / joplin-export: the CronJob runs as 1000:1000 (the node
#   image's "node" user) and owns all four subdirs (npm prefix, joplin
#   profile, export tree)
set -euo pipefail
mkdir -p /srv/appdata/{hermes,openviking,joplin-cli,joplin-export}
chown 10000:10000 /srv/appdata/hermes
chmod 750 /srv/appdata/hermes
chown root:root /srv/appdata/openviking
chmod 750 /srv/appdata/openviking
chown 1000:1000 /srv/appdata/joplin-cli /srv/appdata/joplin-export
chmod 750 /srv/appdata/joplin-cli /srv/appdata/joplin-export
ls -ld /srv/appdata/{hermes,openviking,joplin-cli,joplin-export}
