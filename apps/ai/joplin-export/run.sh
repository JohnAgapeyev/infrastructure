#!/usr/bin/env bash
# joplin-export job script (embedded into the joplin-export-script
# ConfigMap by kustomize configMapGenerator - this file is the single
# source of truth).
#
# Pipeline (AI-2, OC-2): the OFFICIAL Joplin CLI runs as one more sync
# client of the owner's existing Nextcloud WebDAV sync target (like their
# phone), exports a clean markdown tree (notebook folders, title-named
# files). Nothing anywhere reads the raw Joplin sync directory (internal
# uuid/metadata format - rejected by design, D4).
#
# OC phase (2026-10-20): the OpenViking upsert leg (`ov add-resource` +
# the @openviking/cli install) was REMOVED - the openclaw pod indexes the
# export tree directly (read-only mount + memory.search.extraPaths, D13).
# Revert procedure (git history + ~/.opencode/plan/openclaw-joplin.md):
# restore the ov CLI install, the ovcli.conf copy + `ov language` leg and
# the `ov add-resource` upsert from git.
#
# Pinned versions live below; bump deliberately (operations.md "AI ops"),
# Dependabot cannot see npm versions inside this script (same accepted
# limitation as K3S_VERSION).
#
# VERIFY items for the first live run (checked against Joplin CLI docs):
# - one-shot commands are non-interactive BY DEFAULT; there is NO global
#   --non-interactive flag (2026-10-18: "Unknown flag: --non-interactive")
# - sync target numbering, verified against joplin 3.7.1's own enum
#   (2026-10-18): 0 None, 2 File system, 3 OneDrive, 5 Nextcloud,
#   6 WebDAV, 7 Dropbox, 8 S3, 9/10/11 Joplin Server/Cloud/SAML.
#   WebDAV (6) + the full dav URL from JOPLIN_SYNC_URL is the direct
#   mapping of the desktop client's config.
set -euo pipefail

JOPLIN_CLI_VERSION="3.7.1"

# 0. clean any stale temp export from an interrupted previous run
rm -rf /work/state/.export.* || true

# 1. install the pinned Joplin CLI into the persistent npm prefix (repeat
#    runs hit the cache; ~30s cold, near-instant warm). Output NOT
#    silenced: 2026-10-18 lesson - an OOM here leaves completely empty
#    job logs.
npm install -g --prefix "$NPM_PREFIX" --no-audit --no-fund \
  "joplin@${JOPLIN_CLI_VERSION}"

# 1b. some npm tarballs ship JS bin entry points WITHOUT the exec bit
#     (seen 2026-10-18: @openviking/cli bin/ov.mjs 644 -> "Permission
#     denied"); resolve each bin symlink and fix the bit ourselves
for link in "$NPM_PREFIX"/bin/*; do
  [ -L "$link" ] && chmod +x -- "$(readlink -f "$link")" 2>/dev/null || true
done

# 2. Joplin CLI: configure (idempotent) + sync as an additional WebDAV
#    client of the same target the desktop/mobile clients use. One-shot
#    commands are non-interactive by themselves. WebDAV = target 6.
joplin --profile "$JOPLIN_PROFILE" config sync.target 6
joplin --profile "$JOPLIN_PROFILE" config sync.6.path "$JOPLIN_SYNC_URL"
joplin --profile "$JOPLIN_PROFILE" config sync.6.username "$JOPLIN_NC_USER"
joplin --profile "$JOPLIN_PROFILE" config sync.6.password "$JOPLIN_NC_APP_PASSWORD"
joplin --profile "$JOPLIN_PROFILE" sync

# 3. export to a fresh temp dir, then REPLACE the visible export tree
#    (openclaw's read-only mount + debounced reindex picks it up; the full
#    replace means deletions propagate - no stale leftovers for the index)
TMP=$(mktemp -d /work/state/.export.XXXXXX)
joplin --profile "$JOPLIN_PROFILE" export --format md "$TMP/out"
find "$JOPLIN_EXPORT_DIR" -mindepth 1 -delete
cp -a "$TMP/out/." "$JOPLIN_EXPORT_DIR/"
rm -rf "$TMP"