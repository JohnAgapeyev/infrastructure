#!/usr/bin/env bash
# Cluster overview: pods, services, recent events, /srv disk usage.
set -euo pipefail
kubectl get pods -A -o wide
echo
kubectl get svc -A
echo
kubectl get events -A --sort-by=.lastTimestamp | tail -20
echo
df -h /srv
