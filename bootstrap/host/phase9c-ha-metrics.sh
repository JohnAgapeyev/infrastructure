#!/usr/bin/env bash
# Phase 9c (optional): enable HA's built-in prometheus integration so
# Prometheus can scrape http://10.0.0.4:8123/api/prometheus (SUDO, ~1 s).
# Prerequisite (user, in the HA UI): Profile -> Security -> Long-lived
# access tokens -> Create Token, then save it as
# /home/john/code/infrastructure/secrets/homeassistant.env using
# secrets/homeassistant.env.example as the template.
# After this script: agent runs `kubectl -n home rollout restart
# deploy/home-assistant`, then wires the ServiceMonitor in
# apps/observability/exporters/kustomization.yaml (see comments there).
# Run as root: sudo bash bootstrap/host/phase9c-ha-metrics.sh
set -euo pipefail

CONF=/srv/appdata/home-assistant/configuration.yaml

if grep -q '^prometheus:' "$CONF"; then
  echo "prometheus: block already present in $CONF - nothing to do"
  exit 0
fi

cat >>"$CONF" <<'EOF'

# added 2026-09-30 (phase 9c): expose metrics at /api/prometheus for the
# Prometheus ServiceMonitor (token in the homeassistant-token Secret)
prometheus:
EOF

echo "OK - restart HA (agent: kubectl -n home rollout restart deploy/home-assistant)"
tail -3 "$CONF"
