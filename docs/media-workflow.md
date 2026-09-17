# Media workflow

(Filled in during Phase 4-6. Draft below from PLAN.md.)

## Request flow (verified end-to-end 2026-09-13)

Seerr (http://seerr.lan) -> Radarr/Sonarr -> qBittorrent (category) -> import
via hardlink (nlink=2 verified) -> library rename to `[tmdbid/tvdbid]` format
-> Jellyfin library update via Connect -> Seerr "Available".

Test run: Night of the Living Dead (public domain) via 1337x/YTS -> imported
and visible in Jellyfin, then removed. Public-tracker releases score -10000
(LQ/Obfuscated CFs) as designed; the arr stack still grabs them when manually
selected or when nothing better exists.

Notes:
- Legacy pre-migration torrents in categories Movies/TV sit in the arr queue
  as "completed/warning: unable to parse" (cosmetic). Some parsed and
  re-imported as "upgrades"; the replaced links land in
  `/srv/Media/Torrents/.recycle` (same inode, 14-day cleanup).
- Radarr 5.28.0 could not authenticate to qBittorrent 5.2.3 (qb 5.2 returns
  HTTP 204 on login; fixed in Radarr >= 6.3.0) - that is why Radarr runs 6.3.0.
- Radarr `chownGroup` is left empty: the group name `media` does not exist
  inside LSIO containers ("Unknown group"). Setgid dirs + UMASK=002 already
  give group media write access.
- qBittorrent WebUI whitelist is 10.0.0.0/24 ONLY (LAN). The earlier
  10.42.0.0/16 entry broke arr client logins (204 login vs "Ok." body).
  Cluster clients authenticate with credentials (secrets/qbittorrent.env).

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

Existing anime is owned by Shoko Server v5.3.3 (AniDB hash matching; scan
completed 2026-09-14: 3377 files, 225 series), exposed to Jellyfin through
Shokofin 6.0.5.11 in VFS mode: the plugin generates a virtual
Season/episode structure (symlinks) under
`/srv/appdata/jellyfin/Shokofin/VFS/<library-id>/`, and the Jellyfin
"Anime" library (Shows, Shoko-only providers) points at that VFS root.
Episodes resolve back to the real files under /srv/Media/Anime.

Operational notes (learned 2026-09-14):
- Shokofin maps a Jellyfin library folder to Shoko's import folder by
  sampling ~101 files and asking Shoko if it knows them. If the mapping
  fails (`IsMapped: false`, VFS stays empty), retrigger once Shoko has
  indexed the files: set `NeedsRefresh: true` on the library folder entry
  via the plugin configuration API, then POST /Library/Refresh.
- Keep the Shoko import folder's DropFolderType at "None": "Source" makes
  Shoko open files ReadWrite, which fails on the deliberately read-only
  media mount ("Failed to access" hash errors).
- Library structure is "Shoko Groups" (plugin setting
  DefaultLibraryStructure=Shoko_Groups -> UseGroupsForShows): each Shoko
  group renders as ONE show, with each member AniDB series as a season
  (e.g. "Attack on Titan" = S1..Final Season + Specials). Structure
  changes need a forced full VFS regeneration
  (IterativeVfsGeneration_ForceFullGenerationOnNextRefresh=true) plus a
  library scan.

Sonarr handles NEW anime via root folder /srv/Media/Anime + profile
"Anime"; Shoko's watcher (SignalR -> Shokofin) picks the new files up
automatically.

## Quality / upgrades

Single Radarr + single Sonarr with TRaSH profiles synced by Recyclarr
(daily CronJob). Upgrades allowed up to Remux-2160p cutoff. The arr stack
grabs the BEST-scoring release available at request time, then upgrades via
RSS until the cutoff; it does not deliberately grab a small file first.

## Indexers

Prowlarr manages indexers and syncs them to Radarr/Sonarr. Public trackers
are the weak link; adding a private tracker later improves everything.
