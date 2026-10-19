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
# Pinned versions live below; bump deliberately (operations.md "AI ops"),
# Dependabot cannot see npm versions inside this script (same accepted
# limitation as K3S_VERSION).
#
# VERIFY items for the first live run (checked against Joplin CLI docs):
# - `joplin --profile <dir> config <key> <value>` writes settings.sqlite
#   in the profile; sync.target 4 = WebDAV (sync.4.* keys)
# - `--non-interactive` keeps sync/export prompt-free
# - `export --format md` into a NOT-yet-existing dir (hence "$TMP/out")
set -euo pipefail

JOPLIN_CLI_VERSION="3.7.1"
OV_CLI_VERSION="0.4.23"

# 0. clean any stale temp export from an interrupted previous run
rm -rf /work/state/.export.* || true

# 1. install pinned CLIs into the persistent npm prefix (repeat runs hit
#    the cache; ~30s cold, near-instant warm)
npm install -g --prefix "$NPM_PREFIX" --no-audit --no-fund \
  "joplin@${JOPLIN_CLI_VERSION}" "@openviking/cli@${OV_CLI_VERSION}" >/dev/null

# 2. ov CLI config: the Secret mount is read-only and `ov language`
#    writes to the config file - copy it into the writable state dir first
cp /work/secrets/ovcli.conf "$OPENVIKING_CLI_CONFIG_FILE"
ov language en

# 3. Joplin CLI: configure (idempotent) + sync as an additional WebDAV
#    client of the same target the desktop/mobile clients use
joplin --profile "$JOPLIN_PROFILE" --non-interactive config sync.target 4
joplin --profile "$JOPLIN_PROFILE" --non-interactive config sync.4.path "$JOPLIN_SYNC_URL"
joplin --profile "$JOPLIN_PROFILE" --non-interactive config sync.4.username "$JOPLIN_NC_USER"
joplin --profile "$JOPLIN_PROFILE" --non-interactive config sync.4.password "$JOPLIN_NC_APP_PASSWORD"
joplin --profile "$JOPLIN_PROFILE" --non-interactive sync

# 4. export to a fresh temp dir, then REPLACE the visible export tree
#    (only reader is step 5, which runs strictly after the swap; deletions
#    must reach step 5, hence the full replace - no stale leftovers)
TMP=$(mktemp -d /work/state/.export.XXXXXX)
joplin --profile "$JOPLIN_PROFILE" --non-interactive export --format md "$TMP/out"
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
