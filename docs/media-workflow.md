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

Quality bands (recyclarr-synced, 2026-10-12). Band semantics: qualities
list = ceiling; until_quality (= the *arr cutoff) = what "done" means;
until_score ("Upgrade Until Custom Format Score") = churn appetite.
until_score 10000 = "any score improvement is worth a re-download" - that
manufactured the partial-pack/missingFiles waste; new values cap it.
Assign per movie/series in the *arr UI; HD->UHD Upgrade keeps its legacy
name because it holds all pre-existing assignments.

| Band (both apps) | Ceiling | Cutoff | until_score | For |
|---|---|---|---|---|
| HD->UHD Upgrade | Remux | Remux-2160p | 500 | "deserves the best" |
| UHD Preferred | Remux | WEBDL-2160p | 100 | "4K if possible, 1080p okay" |
| 1080p Good Enough | Bluray-1080p (720p floor) | WEBDL-1080p | 100 | "don't care much"; 720p-only releases still import and upgrade if a 1080p ever appears |

Sonarr additionally: Anime (upgrades ON, cutoff Bluray-1080p Remux,
until_score 100 - ongoing/airing shows; mid-run supersession breaks
packs, accepted for ongoing shows) and Anime Archive (upgradeAllowed
FALSE - finished series: best batch once, pack stays whole forever;
flip a series here when it ends; Sonarr's API requires a valid cutoff
even with upgrades off, hence the placeholder until_quality).

TRaSH profiles synced daily by recyclarr; owner deviations (x265 not
penalised, Anime Dual Audio +1000 / Uncensored +500) unchanged.

## Seeding cleanup / garbage collection (qbit_manage CronJob)

Owner intent (2026-10-12): seed forever WHILE content is in the library;
remove the torrent when its payload is no longer hardlinked into a
library (quality-rejected / superseded / library-deleted). NOT
age/ratio-based. The oracle for "in my library" is the HARDLINK (*arr
imports hardlink; payload files with st_nlink >= 2 ARE the library file
- verified inode-identical on Mad Men S04E06 and Mushoku S03E14 Cytox).

Ongoing GC is `apps/media/qbit-manage/` (bobokun/qbit_manage v4.13.0,
CronJob 04:45 daily, dry-run toggle in its configmap):
- `tag_nohardlinks` on the *arr categories (Movies, TV, anime-sonarr):
  largest-file nlink check; links outside the torrent root = in library.
- `share_limits`: noHL-tagged torrents get 14d max/min seeding (old
  torrents removed next run; fresh supersessions seed up to 14d more);
  Stop action + qbm cleanup deletes through the recycle bin
  (`/srv/Media/Torrents/.qbm-recycle`, emptied after 14d - matches the
  *arr `.recycle` window; .torrent/.fastresume copies kept for re-add).
  The default group resets everything else to no limits (seed forever).
- Deliberately OFF: `recheck` (would RE-DOWNLOAD superseded/missingFiles
  content - never enable), `rem_orphaned` (revisit later),
  cat/tracker tagging (out of scope).
- qbm pod mounts BOTH path views (/srv/Media + /srv/misc/torrents):
  torrent history has mixed content_path forms; with only the
  /srv/misc view, every host-form torrent reads as no-hardlinks
  (first dry run showed 706 false noHL before the fix).
- qbm's no-hardlinks check is per-torrent LARGEST-FILE: a season pack
  whose biggest file was superseded gets cleaned even if other
  episodes are still linked - coarser than per-file.
- Dry-run caveat: `disable_qbt_default_share_limits` applies even in
  dry-run (qb global share limits got disabled during the first dry run).
- Legacy qb categories Anime (137) / Porn point INTO library dirs
  (pre-migration); excluded from nohardlinks, left seed-forever.

`scripts/qbit-cleanup.sh` remains for what qbm cannot do: the
missingFiles errored-entry sweep (87 entries at last run) and per-file
partial-pack reporting; run manually when desired.

Second dry run (2026-10-12, config as committed): Movies 103/353, TV
56/308, anime-sonarr 176/706 noHL; total 335. Spot-checks: Witcher
720p / Prometheus / Godfather superseded releases tagged; library-linked
files not.

## qBittorrent seeding config (2026-10-12)

- Global ratio limit DISABLED (was max_ratio 10 + action super-seed:
  302 healthy torrents had silently flipped into super-seeding =
  initial-seeding mode, engineered to MINIMIZE upload to the swarm -
  exactly the wrong torrents to ration). Per-torrent super-seeding
  flags cleared (POST setSuperSeeding hashes=all value=false; this qb
  build does not expose super_seeding on the properties endpoint, so
  no API read-back - the 200 + prefs is the verification).
- Queueing DISABLED (all torrents seed concurrently - the "go wide"
  strategy), upload slots rate-based, fastest-upload choking,
  coalesced read/write. Upload cap 25 MB/s.
- qbm owns share limits per its share_limits groups (see above).

## Indexers

Prowlarr manages indexers and syncs them to Radarr/Sonarr. Public trackers
are the weak link; adding a private tracker later improves everything.
