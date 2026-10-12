# TLS (split DNS + wildcard)

Valid TLS for all web UIs on `*.home.jg-a.com`, terminating at Traefik.

## Chain

```
Cloudflare (authoritative NS for jg-a.com)
  --DNS-01 (API token)-->  cert-manager (k3s)
  --> wildcard *.home.jg-a.com --> Secret wildcard-tls (kube-system)
  --> Traefik TLSStore default.defaultCertificate
  --> all Ingresses (tls.hosts only, no per-app secret)
Clients: OPNsense Unbound wildcard host override *.home.jg-a.com -> 10.0.0.4
```

Pieces:

- `scripts/install-cert-manager.sh` - cert-manager v1.21.2 pinned, with
  `--feature-gates=ACMEUseARI=true` on the controller (RFC 9773: LE can
  force early renewal - mass revocation / CA key rollover).
- `cluster/cert-manager/` - ClusterIssuer `letsencrypt` (dns01 Cloudflare
  token from `secrets/certmanager.env`) + Certificate `wildcard-home-jga`
  in `kube-system` (Traefik's namespace; the TLSStore-referenced Secret
  must live there). Both dnsNames `home.jg-a.com` AND `*.home.jg-a.com` -
  a wildcard alone does not cover the apex of its own label.
- `cluster/traefik/helmchartconfig.yaml` - k3s bundled-Traefik
  HelmChartConfig: TLSStore default cert = `wildcard-tls`, and permanent
  HTTP->HTTPS redirect on the web entrypoint.
- `apps/observability/{exporters,rules}/cert-manager.yaml` - metrics
  scrape + alerts (CertificateNotReady / CertificateExpiringSoon /
  CertificateScrapeMissing).

Renewal is fully automatic:

- No `renewBefore` is set: cert-manager derives the renewal date from each
  issued cert's actual notBefore/notAfter (~2/3 through lifetime). When LE
  cuts lifetimes (64d on 2027-02-10, 45d on 2028-02-16 - see
  letsencrypt.org/2025/12/02/from-90-to-45), nothing here changes.
- ARI (enabled above) additionally honors CA-requested renewal windows.
- The 2028 authz-reuse cut (30d -> 7h) is irrelevant to DNS-01: every
  renewal proves control from scratch via a new `_acme-challenge` TXT.

## OPNsense Unbound (split DNS) - ONE-TIME / MANUAL

Services -> Unbound DNS -> Overrides -> Host Overrides:

| Host | Domain | Type | Value |
|---|---|---|---|
| `*` | `home.jg-a.com` | A | `10.0.0.4` |

Notes:

- The wildcard override makes `_acme-challenge.home.jg-a.com` TXT queries
  return NODATA from the LAN resolver, which is why the ClusterIssuer sets
  solver-level `waitInsteadOfSelfCheck: 2m` (skips cert-manager's own
  self-check; LE validates against Cloudflare directly, Unbound is not
  involved in validation at all).
- Keep the override a WILDCARD, not per-host entries: new services then
  need only a k3s Ingress, zero DNS changes.
- No `home.jg-a.com` records need to exist in Cloudflare. Only transient
  `_acme-challenge` TXT records appear there during issuance/renewal
  (created and deleted by cert-manager).

## Cloudflare token - ONE-TIME / MANUAL

Dashboard -> My Profile -> API Tokens -> Create Token -> "Edit zone DNS":

- Permissions: `Zone - DNS - Edit`, `Zone - Zone - Read`
- Zone Resources: `Include - Specific zone - jg-a.com`

Put the token in `secrets/certmanager.env` (`CLOUDFLARE_API_TOKEN=...`)
and `make apply-cluster`. Rotation = roll the token in the Cloudflare
dashboard, update the env file, `make apply-cluster` (alerts will fire if
the old one dies first - CertificateNotReady).

## New service checklist

1. Add `<app>/ingress.yaml` with host `<slug>.home.jg-a.com` and a
   `spec.tls.hosts` entry (no `secretName`).
2. `make apply-<category>`.

No cert, no Traefik config, no DNS change.

## Troubleshooting

- `kubectl get certificate -A` / `kubectl get challenges -A` -
  Ready must be True; last issued cert in `wildcard-tls`
  (`kubectl -n kube-system get secret wildcard-tls -o jsonpath='{.data ca\.crt}'` absent is normal;
  check `tls.crt` dates with openssl).
- `kubectl -n cert-manager logs deploy/cert-manager` - ACME flow detail.
- `kubectl -n kube-system get tlsstore default -o yaml` - must reference
  `wildcard-tls`; Traefik restarts pick up new certs automatically
  (kube-system pod `helm-install-traefik-*` reruns on HelmChartConfig
  changes).
- Renewal test: `kubectl -n kube-system annotate certificate
  wildcard-home-jga cert-manager.io/renew=true` (or `cmctl renew`).