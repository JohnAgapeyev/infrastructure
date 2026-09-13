#!/usr/bin/env bash
# k3s install AND upgrade path. Pinned version; NEVER the AUR package.
# To upgrade: edit K3S_VERSION (one Kubernetes minor at a time), commit,
# `sudo bash bootstrap/k3s/install.sh` (restarts k3s; running pods survive;
# API gone ~20 s). Rollback = set old version, rerun.
set -euo pipefail

K3S_VERSION="v1.36.4+k3s1"   # latest stable 2026-09-13 (github.com/k3s-io/k3s/releases)

install -D -m 0644 "$(dirname "$0")/config.yaml" /etc/rancher/k3s/config.yaml
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
install -D -m 0644 "$(dirname "$0")/k3s.service.d-override.conf" /etc/systemd/system/k3s.service.d/override.conf
systemctl daemon-reload

echo "installed k3s ${K3S_VERSION}"
