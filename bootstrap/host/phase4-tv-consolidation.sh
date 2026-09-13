#!/usr/bin/env bash
# Phase 4 (plan 8.8): TV library consolidation - RENAMES ONLY.
# Groups raw release-dumps into Sonarr-parseable series folders.
# Every operation is an `mv` (instant rename) inside /srv/Media/TV (device 64515).
# Run as root: sudo bash bootstrap/host/phase4-tv-consolidation.sh
set -euo pipefail

TV=/srv/Media/TV

# guard: same filesystem as /srv/Media
[ "$(stat -c %d "$TV")" = "64515" ] || { echo "unexpected device for $TV" >&2; exit 1; }

# --- Peaky Blinders: 6 flat season dumps -> series folder -------------------
mkdir -p "$TV/Peaky Blinders (2013)"
for i in 1 2 3 4 5 6; do
  mv "$TV/Peaky.Blinders.S0${i}.1080p.BluRay.x265-RARBG" "$TV/Peaky Blinders (2013)/Season 0${i}"
done

# --- The Flash: S01-S07 (subdirs) + S08 + S09 (flat) -> series folder --------
mkdir -p "$TV/The Flash (2014)"
F7="$TV/The Flash S01-S07 br 10bit ddp hevc-d3g"
for i in 1 2 3 4 5 6 7; do
  mv "$F7/Flash S0${i}" "$TV/The Flash (2014)/Season 0${i}"
done
rmdir "$F7"
mv "$TV/The Flash S08 br 10bit dtd hevc-d3g" "$TV/The Flash (2014)/Season 08"
mv "$TV/The Flash S09 web hevc-d3g"          "$TV/The Flash (2014)/Season 09"

# --- The Sopranos: S01-S06 subdirs -> series folder --------------------------
mkdir -p "$TV/The Sopranos (1999)"
SO="$TV/The Sopranos S01-S06 web hevc-d3g"
for i in 1 2 3 4 5 6; do
  mv "$SO/The Sopranos S0${i}" "$TV/The Sopranos (1999)/Season 0${i}"
done
rmdir "$SO"

# --- Frasier: dir rename + normalize season subdir names ---------------------
mv "$TV/Frasier (1993) Season 1-11 S01-S11 (Mixed x265 HEVC 10bit AC3-EAC3 2.0 Silence)" "$TV/Frasier (1993)"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  n=$(printf '%02d' "$i")
  from=$(find "$TV/Frasier (1993)" -maxdepth 1 -type d -name "Season $i (*)" | head -1)
  [ -n "$from" ] && mv "$from" "$TV/Frasier (1993)/Season $n"
done

# --- MASH: dir rename only (Sxx subdirs already parse) -----------------------
mv "$TV/MASH - Martinis and Medicine Complete Collection" "$TV/MASH (1972)"

# --- The Office: dir rename + normalize season subdir names ------------------
mv "$TV/The Office (US) (2005) Season 1-9 S01-S09 (1080p Mixed x265 HEVC 10bit AAC 5.1 Silence)" "$TV/The Office (US) (2005)"
for i in 1 2 3 4 5 6 7 8 9; do
  n=$(printf '%02d' "$i")
  from=$(find "$TV/The Office (US) (2005)" -maxdepth 1 -type d -name "Season $i (*)" | head -1)
  [ -n "$from" ] && mv "$from" "$TV/The Office (US) (2005)/Season $n"
done

# --- The West Wing: dir rename only (Season NN subdirs already fine) ---------
mv "$TV/The West Wing Season 1-7 S01-S07 (1080p AMZN WEB-DL x265 HEVC EAC3 2.0 ImE) [QxR]" "$TV/The West Wing (1999)"

echo "== resulting TV tree (top level) =="
ls -1 "$TV"
echo
echo "== new series folders =="
for d in "Peaky Blinders (2013)" "The Flash (2014)" "The Sopranos (1999)" "Frasier (1993)" "MASH (1972)" "The Office (US) (2005)" "The West Wing (1999)"; do
  echo "-- $d"; ls -1 "$TV/$d" | head -14
done
