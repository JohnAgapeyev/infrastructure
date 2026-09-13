# Media workflow

(Filled in during Phase 4-6. Draft below from PLAN.md.)

## Request flow

Seerr (http://seerr.lan) -> Radarr/Sonarr -> qBittorrent (category) -> import
via hardlink -> Jellyfin library update -> Seerr marks Available.

## Categories (qBittorrent)

Existing categories were REUSED (519 torrents reference them); two new ones
added (2026-09-13):

| Category | Save path | Used by |
|---|---|---|
| Movies | `/srv/Media/Torrents/completed/movies` (stored as `/srv/misc/torrents/completed/movies`, resolves via compat mount) | Radarr download client |
| TV | `/srv/Media/Torrents/completed/tv` (stored as `/srv/misc/torrents/completed/tv`, resolves via compat mount) | Sonarr TV client |
| anime-sonarr | `/srv/Media/Torrents/completed/anime` | Sonarr anime client (tagged `anime`) |
| manual | `/srv/Media/Torrents/completed/manual` | manual multi-season packs |
| Anime | `/srv/Media/Anime` | anime batches (Shoko by hash) |
| Porn | `/srv/Media/Porn` | unchanged, no arr integration |

WebUI settings applied via API (Phase 2): localhost auth bypass ON; subnet
whitelist bypass ON (`10.0.0.0/24`, `10.42.0.0/16` - host and pod traffic);
queueing ON with max active downloads 5 / max active torrents 20 (NOTE: caps
concurrently-active seeding torrents at 20; 516 of 519 seed torrents are
queuedUP by design. Change `queueing_enabled`/`max_active_torrents` in
WebUI if seed throughput matters more than disk head-thrash protection);
pre-allocate ON; content layout Original; finished `.torrent` export to
`/srv/Media/Torrents/completed/torrents`.

## Multi-season packs

Sonarr rejects multi-season packs by design. Add the magnet in qBittorrent
with category `manual`; when complete: Sonarr -> Wanted -> Manual Import ->
`/srv/Media/Torrents/completed/manual/<pack>`; Sonarr parses each SxxEyy file
and hardlinks into the series folder. Anime batches: category `anime-direct`
(saves straight into `/srv/Media/Anime`); Shoko identifies by hash.

## Anime

Existing anime is owned by Shoko Server (AniDB hash matching), exposed to
Jellyfin through the Shokofin plugin (VFS). Sonarr only handles NEW anime via
root folder `/srv/Media/Anime` + profile "Anime".

## Quality / upgrades

Single Radarr + single Sonarr with TRaSH profiles synced by Recyclarr
(daily CronJob). Upgrades allowed up to Remux-2160p cutoff. The arr stack
grabs the BEST-scoring release available at request time, then upgrades via
RSS until the cutoff; it does not deliberately grab a small file first.

## Indexers

Prowlarr manages indexers and syncs them to Radarr/Sonarr. Public trackers
are the weak link; adding a private tracker later improves everything.
