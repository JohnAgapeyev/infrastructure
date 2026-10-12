#!/usr/bin/env bash
# Install/upgrade cert-manager from the pinned upstream static manifest.
#
# Not part of `cluster/` kustomize: the upstream manifest is ~10k lines and
# changes with every release, so it is fetched pinned (same policy as
# bootstrap/k3s/install.sh). ClusterIssuer/Certificate (the parts we own)
# live in cluster/cert-manager/ and are applied with `make apply-cluster`.
#
# ARI: LE moves to 64-day certs on 2027-02-10 and 45-day on 2028-02-16
# (letsencrypt.org/2025/12/02/from-90-to-45). cert-manager derives renewal
# time from each issued cert's actual notBefore/notAfter, so no config change
# is needed at those dates. ACMEUseARI (RFC 9773, cert-manager >= 1.21)
# additionally lets the CA force early renewal (mass revocation / key
# rollover), so we enable it on the controller.
set -euo pipefail

CERT_MANAGER_VERSION="v1.21.2"
MANIFEST="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
NAMESPACE="cert-manager"

echo "Applying cert-manager ${CERT_MANAGER_VERSION} static manifest..."
curl -fsSL "${MANIFEST}" | kubectl apply -f -

echo "Waiting for cert-manager deployments..."
kubectl -n "${NAMESPACE}" wait --for=condition=Available deploy/cert-manager --timeout=300s
kubectl -n "${NAMESPACE}" wait --for=condition=Available deploy/cert-manager-webhook --timeout=300s
kubectl -n "${NAMESPACE}" wait --for=condition=Available deploy/cert-manager-cainjector --timeout=300s

# Idempotently enable the ACMEUseARI feature gate on the controller.
# (The static manifest is re-applied verbatim on upgrade, so the arg must be
# re-added after every run of this script; hence check-then-patch.)
if kubectl -n "${NAMESPACE}" get deploy cert-manager \
     -o jsonpath='{.spec.template.spec.containers[0].args}' \
   | grep -q 'ACMEUseARI'; then
  echo "ACMEUseARI feature gate already set."
else
  echo "Enabling ACMEUseARI feature gate on cert-manager controller..."
  kubectl -n "${NAMESPACE}" patch deploy cert-manager --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--feature-gates=ACMEUseARI=true"}]'
  kubectl -n "${NAMESPACE}" rollout status deploy/cert-manager --timeout=300s
fi

echo "cert-manager ${CERT_MANAGER_VERSION} installed (ACMEUseARI enabled)."
echo "Next: make apply-cluster   # ClusterIssuer + wildcard Certificate"