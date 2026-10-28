#!/usr/bin/env bash
# Build the launcher's map library from a retail install.
#
#   bash prepare_library.sh --yr <Yuri's Revenge dir> --ra2 <Red Alert 2 dir> \
#        [--mod <overlay pack dir>] [--library <dir>]
#
# The library holds everything the launcher reads, so it never has to touch a
# protected folder (macOS blocks the first access to Downloads/Documents):
#
#   base/            APFS clone of the YR install (shared blocks, ~0 extra space)
#   base-mod/        base + a mod pack's files on top (when --mod is given)
#   meta-base/       MISSIONMD.INI + ra2md.csf from the YR install
#   meta-ra2/        ra2.csf from the Red Alert 2 install
#   meta/            the mod's mission table/CSF (falls back to meta-base)
#   campaign/        Yuri's Revenge chapters, extracted by file name
#   ra2-campaign/    Red Alert 2 chapters, extracted by entry id
#   packs/           retail map packs (mapsmd03.mix, multimd.mix)
#   previews/        cached radar renders (written by the launcher)
#
# `map-tool` from the vera20k checkout does every archive lookup.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="${VERA20K_ROOT:-$(cd "$here/../vera20k" 2>/dev/null && pwd || true)}"
tool="${VERA20K_MAP_TOOL:-$root/target/release/map-tool}"
library="${VERA2K_LAUNCHER_LIBRARY:-$HOME/Library/Application Support/VERA20K-Maps}"
data_dir="$HOME/Library/Application Support/VERA20k"
yr=""; ra2=""; mod=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yr) yr="${2:?--yr needs a path}"; shift 2 ;;
    --ra2) ra2="${2:?--ra2 needs a path}"; shift 2 ;;
    --mod) mod="${2:?--mod needs a path}"; shift 2 ;;
    --library) library="${2:?--library needs a path}"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$yr" ] || { echo "--yr <Yuri's Revenge dir> is required" >&2; exit 2; }
[ -x "$tool" ] || { echo "map-tool not found at $tool (set VERA20K_MAP_TOOL)" >&2; exit 1; }

extract() { # archive name out
  "$tool" extract-named "$1" "$2" --out "$3" >/dev/null 2>&1
}
first_hit() { # name expected-out mix candidates...
  local name="$1" out="$2"; shift 2
  for mix in "$@"; do
    if extract "$mix" "$name" "$out"; then
      return 0
    fi
  done
  return 1
}

mkdir -p "$library"/{meta-base,meta-ra2,meta,campaign,ra2-campaign,packs,previews,maps}
echo "library: $library"

# 1. Base install: a clone shares blocks with the source, so it costs nothing.
if [ ! -d "$library/base" ] || [ -z "$(ls -A "$library/base" 2>/dev/null)" ]; then
  mkdir -p "$library/base"
  cp -c "$yr"/* "$library/base"/ 2>/dev/null || cp -R "$yr"/* "$library/base"/
  echo "cloned base install"
fi

# 2. Mission tables and string tables.
# MISSIONMD.INI is not stored under its own name inside the packs; the vera20k
# checkout's `extract-ini` binary produces it from the archive name table, so
# reuse that copy when the checkout has one.
if first_hit missionmd.ini "$library/meta-base/MISSIONMD.INI" \
    "$library/base/ra2md.mix" "$library/base/langmd.mix" "$library/base/language.mix"; then
  echo "meta-base: MISSIONMD.INI"
elif [ -f "$root/ini/missionmd.ini" ]; then
  cp "$root/ini/missionmd.ini" "$library/meta-base/MISSIONMD.INI"
  echo "meta-base: MISSIONMD.INI (from $root/ini)"
else
  echo "warn: no MISSIONMD.INI; Yuri's Revenge chapters will fall back to file names" >&2
  echo "      run (cd $root && cargo run --release --bin extract-ini) to generate it" >&2
fi
first_hit ra2md.csf "$library/meta-base/ra2md.csf" \
  "$library/base/langmd.mix" "$library/base/language.mix" \
  && echo "meta-base: ra2md.csf"
if [ -n "$ra2" ]; then
  first_hit ra2.csf "$library/meta-ra2/ra2.csf" \
    "$ra2/language.mix" "$ra2/ra2.mix" "$ra2/expand01.mix" \
    && echo "meta-ra2: ra2.csf"
fi

# 3. Yuri's Revenge chapters, by their retail file names.
yr_missions="SOV01UMD SOV02SMD SOV03UMD SOV04DMD SOV05UMD SOV06LMD SOV07TMD
ALL01UMD ALL02UMD ALL03UMD ALL04DMD ALL05UMD ALL06UMD ALL07SMD
C1A01MD C2S01MD C3Y01MD C4W01MD"
count=0
for mission in $yr_missions; do
  if first_hit "$mission.MAP" "$library/campaign/$mission.MAP" \
      "$library/base/mapsmd03.mix" "$library/base/multimd.mix" \
      "$library/base/expandmd01.mix" "$library/base/expandmd02.mix"; then
    count=$((count + 1))
  fi
done
echo "campaign: $count maps"

# 4. Red Alert 2 chapters: the packs are hash-named, so every entry is tried and
#    the map's own [Basic] Briefing key (ALL01/SOV03/TRN01) identifies it later.
if [ -n "$ra2" ]; then
  mkdir -p "$library/packs"
  for pack in Maps01 Maps02; do
    [ -f "$ra2/$pack.mix" ] || continue
    for id in $("$tool" mix "$ra2/$pack.mix" | tail -n +2 | awk -F'\t' '{print $8}'); do
      "$tool" mix "$ra2/$pack.mix" --extract "$id" \
        --out "$library/ra2-campaign/${pack}_${id}.map" >/dev/null 2>&1 || true
    done
  done
  echo "ra2-campaign: $(ls "$library/ra2-campaign" | wc -l | tr -d ' ') maps"
fi

# 5. Retail map packs for the launcher's "packed" section.
for pack in mapsmd03.mix multimd.mix; do
  [ -f "$library/base/$pack" ] && cp -c "$library/base/$pack" "$library/packs/$pack" 2>/dev/null \
    || cp "$library/base/$pack" "$library/packs/$pack" 2>/dev/null || true
done

# 6. Optional mod overlay: base files first, the pack wins by name.
target="$library/base"
if [ -n "$mod" ] && [ -d "$mod" ]; then
  target="$library/base-mod"
  rm -rf "$target"
  mkdir -p "$target"
  cp -c "$library/base"/* "$target"/ 2>/dev/null || cp -R "$library/base"/* "$target"/
  for file in "$mod"/*; do
    [ -f "$file" ] || continue
    cp "$file" "$target/$(basename "$file")"
  done
  # The mod's own mission text: its CSF first, then its map pack's MISSIONMD.
  for file in "$mod"/*.csf "$mod"/*.CSF; do
    [ -f "$file" ] && cp "$file" "$library/meta/ra2md.csf"
  done
  for mix in "$mod"/*.mix; do
    [ -f "$mix" ] || continue
    extract "$mix" missionmd.ini "$library/meta/MISSIONMD.INI" && break
  done
  [ -f "$library/meta/MISSIONMD.INI" ] || cp "$library/meta-base/MISSIONMD.INI" "$library/meta/MISSIONMD.INI" 2>/dev/null || true
  [ -f "$library/meta/ra2md.csf" ] || cp "$library/meta-base/ra2md.csf" "$library/meta/ra2md.csf" 2>/dev/null || true
  # The mod's loose maps are what the "maps" section lists.
  for file in "$mod"/*.map "$mod"/*.mpr "$mod"/*.yrm; do
    [ -f "$file" ] && cp "$file" "$library/maps/"
  done
  echo "profile: $target"
fi

# 7. Point the engine at that asset root (its config.toml lives in the data dir).
mkdir -p "$data_dir"
config="$data_dir/config.toml"
if [ -f "$config" ]; then
  if grep -q '^ra2_dir' "$config"; then
    /usr/bin/sed -i '' "s|^ra2_dir.*|ra2_dir = \"$target\"|" "$config"
  else
    printf 'ra2_dir = "%s"\n' "$target" >> "$config"
  fi
else
  printf '[paths]\nra2_dir = "%s"\n' "$target" > "$config"
fi
echo "engine Assets: $target (config: $config)"
echo "done — build the app with: VERA20K_ROOT=$root bash build.sh"
