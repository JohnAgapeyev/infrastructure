#!/usr/bin/env bash
# LET-0 host prep (run with sudo). Creates the Letta App Server state dir.
# The official image (ghcr.io/letta-ai/letta-code) keeps its state at
# /root/.letta -> hostPath /srv/appdata/letta, and the upstream deployment
# repo runs it as root with no USER override - so the dir is root-owned
# 0:0 (NOT a 1000-class user like openclaw/joplin-export).
# VERIFY on first boot: if the image runs as a different user, fix the
# chown here and in docs/storage-layout.md (openclaw C1 precedent).
set -euo pipefail
mkdir -p /srv/appdata/letta
chown 0:0 /srv/appdata/letta
chmod 750 /srv/appdata/letta
ls -ld /srv/appdata/letta