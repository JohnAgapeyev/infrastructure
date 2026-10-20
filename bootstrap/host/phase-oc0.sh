#!/usr/bin/env bash
# OC-0 host prep (run with sudo). Creates the OpenClaw state dir.
# The official image (ghcr.io/openclaw/openclaw) is node-based and keeps its
# state at /home/node/.openclaw -> hostPath /srv/appdata/openclaw. Owned
# 1000:1000 (= the image's "node" user, same as the joplin-export dirs; note
# host uid 1000 is also john - owner-inspectable by design).
# VERIFY on first boot: if the image runs as a different user, fix the chown
# here and in docs/storage-layout.md.
set -euo pipefail
mkdir -p /srv/appdata/openclaw
chown 1000:1000 /srv/appdata/openclaw
chmod 750 /srv/appdata/openclaw
ls -ld /srv/appdata/openclaw