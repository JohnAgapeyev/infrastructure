#!/usr/bin/env bash
# joplin-export job script (embedded into the joplin-export-script
# ConfigMap by kustomize configMapGenerator - this file is the single
# source of truth).
#
# Pipeline (AI-2): the OFFICIAL Joplin CLI runs as one more sync client of
# the owner's existing Nextcloud WebDAV sync target (like their phone),
# exports a clean markdown tree (notebook folders, title-named files), and
# upserts it into OpenViking. Nothing anywhere reads the raw Joplin sync
# directory (internal uuid/metadata format - rejected by design, D4).
#
# H2 phase (2026-10-21): the OpenViking upsert leg (`ov add-resource` +
# the @openviking/cli install + the ovcli.conf copy + `ov language`) is
# RESTORED (precise revert of OC-2 / 0f98098) - openclaw is disabled and
# Hermes + OpenViking are the agent + memory again. Memory-gap note: notes
# added between OC and H2 were never in OpenViking; the first upsert run
# after this restore backfills them (upsert semantics: changed files
# re-embed, missing content drops out). VERIFY the first run fits the
# 300s deadline - the original AI phase bootstrapped the FIRST sync via a
# one-off pod because the initial vault download overran it (same trick
# applies if the first backfill upsert overruns).
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
OV_CLI_VERSION="0.4.23"

# 0. clean any stale temp export from an interrupted previous run
rm -rf /work/state/.export.* || true

# 1. install pinned CLIs into the persistent npm prefix (repeat runs hit
#    the cache; ~30s cold, near-instant warm). Output NOT silenced:
#    2026-10-18 lesson - an OOM here leaves completely empty job logs.
npm install -g --prefix "$NPM_PREFIX" --no-audit --no-fund \
  "joplin@${JOPLIN_CLI_VERSION}" "@openviking/cli@${OV_CLI_VERSION}"

# 1b. some npm tarballs ship JS bin entry points WITHOUT the exec bit
#     (seen 2026-10-18: @openviking/cli bin/ov.mjs 644 -> "Permission
#     denied"); resolve each bin symlink and fix the bit ourselves
for link in "$NPM_PREFIX"/bin/*; do
  [ -L "$link" ] && chmod +x -- "$(readlink -f "$link")" 2>/dev/null || true
done

# 2. ov CLI config (H2 restore): the Secret mount is read-only and
#    `ov language` writes to the config file - copy it into the writable
#    state dir first
cp /work/secrets/ovcli.conf "$OPENVIKING_CLI_CONFIG_FILE"
ov language en

# 3. Joplin CLI: configure (idempotent) + sync as an additional WebDAV
#    client of the same target the desktop/mobile clients use. One-shot
#    commands are non-interactive by themselves. WebDAV = target 6.
joplin --profile "$JOPLIN_PROFILE" config sync.target 6
joplin --profile "$JOPLIN_PROFILE" config sync.6.path "$JOPLIN_SYNC_URL"
joplin --profile "$JOPLIN_PROFILE" config sync.6.username "$JOPLIN_NC_USER"
joplin --profile "$JOPLIN_PROFILE" config sync.6.password "$JOPLIN_NC_APP_PASSWORD"
joplin --profile "$JOPLIN_PROFILE" sync

# 4. export to a fresh temp dir, then REPLACE the visible export tree
#    (only reader is step 5, which runs strictly after the swap; deletions
#    must reach step 5, hence the full replace - no stale leftovers)
TMP=$(mktemp -d /work/state/.export.XXXXXX)
joplin --profile "$JOPLIN_PROFILE" export --format md "$TMP/out"
find "$JOPLIN_EXPORT_DIR" -mindepth 1 -delete
cp -a "$TMP/out/." "$JOPLIN_EXPORT_DIR/"
rm -rf "$TMP"

# 5. upsert into OpenViking: an add_resource with an explicit existing `to`
#    REFRESHES the target - changed files re-embed, unchanged content is
#    reused, files missing from the source drop out. NEVER pass
#    --watch-interval here: watch_interval <= 0 with an explicit `to` can
#    pause/409 against watch ownership rules; there is no watch on this
#    target and we want none (the job IS the cadence).
ov add-resource "$JOPLIN_EXPORT_DIR" --to viking://resources/joplin
