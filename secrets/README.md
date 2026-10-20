# secrets/

Real secret files (`*.env`, `*.yml`) are gitignored. For every file here there
is a committed `*.example` describing the required keys. Values are consumed
by kustomize `secretGenerator` in the app kustomizations.

| File | Keys | Used by |
|---|---|---|
| `qbittorrent.env` | `QBIT_WEBUI_USER`, `QBIT_WEBUI_PASS` | scripts/qbit-verify-paths.sh, exporters |
| `arr.env` | `RADARR_APIKEY`, `SONARR_APIKEY`, `PROWLARR_APIKEY`, `BAZARR_APIKEY` | unpackerr, recyclarr, exportarr, seerr config docs |
| `jellyfin.env` | `JELLYFIN_APIKEY` | arr Connect, seerr, jellyfin exporter |
| `bazarr.env` | `OPENSUBTITLES_USER`, `OPENSUBTITLES_PASS` | bazarr provider |
| `shoko.env` | `SHOKO_USER`, `SHOKO_PASS`, `ANIDB_USER`, `ANIDB_PASS` | shoko first run |
| `grafana.env` | `admin-user`, `admin-password` | kube-prometheus-stack |
| `alertmanager-ntfy-auth.yml` | `ntfy.auth.token` | observability notify kustomization (bridge -> ntfy; mint via the runbook in apps/observability/notify/) |
| `ntfy.env` | `NTFY_USER`, `NTFY_PASSWORD` | ntfy admin login for the phone/web app (not consumed by any manifest) |
| `certmanager.env` | `CLOUDFLARE_API_TOKEN` | cert-manager dns01 solver (wildcard `*.home.jg-a.com`) |
| `nextcloud.env` | `NEXTCLOUD_ADMIN_USER`, `NEXTCLOUD_ADMIN_PASSWORD`, `POSTGRES_PASSWORD`, `SMTP_HOST`, `SMTP_PORT`, `SMTP_SECURE`, `SMTP_USER`, `SMTP_PASS`, `MAIL_FROM_ADDRESS`, `MAIL_DOMAIN` | nextcloud install (NC-1, first-run envs), postgres |
| `nextcloud-exporter.env` | `NEXTCLOUD_AUTH_TOKEN` | nextcloud-exporter (NC-2; serverinfo app token - `occ config:app:set serverinfo token`) |
| `openclaw.env` | `OPENCLAW_GATEWAY_TOKEN`, `OPENROUTER_API_KEY` | apps/ai/openclaw (OC phase; Control UI token + chat/embeddings key) |
