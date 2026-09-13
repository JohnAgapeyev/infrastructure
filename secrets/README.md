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
