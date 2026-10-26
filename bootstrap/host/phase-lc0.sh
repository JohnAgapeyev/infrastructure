#!/usr/bin/env bash
# LC-0 host prep (run with sudo). Creates the two state dirs for the
# LibreChat front-end. Ownership notes (phase-ai0.sh precedent):
# - librechat: image runs as explicit UID/GID (upstream compose passes
#   ${UID}:${GID}) -> 1000:1000, the same UID as joplin-cli/-export.
#   Two subdirs (images/ uploads/) because the Deployment mounts them
#   as separate hostPaths (type: Directory refuses to auto-create).
# - librechat-mongo: mongo also runs as 1000:1000 (mongo refuses a
#   root-owned data dir).
set -euo pipefail
mkdir -p /srv/appdata/librechat/{images,uploads} /srv/appdata/librechat-mongo
chown 1000:1000 /srv/appdata/librechat /srv/appdata/librechat/images \
  /srv/appdata/librechat/uploads /srv/appdata/librechat-mongo
chmod 750 /srv/appdata/librechat /srv/appdata/librechat/images \
  /srv/appdata/librechat/uploads /srv/appdata/librechat-mongo
ls -ld /srv/appdata/librechat /srv/appdata/librechat/images \
  /srv/appdata/librechat/uploads /srv/appdata/librechat-mongo