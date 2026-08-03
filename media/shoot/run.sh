#!/usr/bin/env bash
# Reshoots every README asset into media/. Usage: media/shoot/run.sh [scene...]
# Requires: nvim, git, rsvg-convert, magick, and tokyonight.nvim on disk.
set -euo pipefail

shoot_dir=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$shoot_dir/../.." && pwd)
work=${SHOOT_WORK:-/tmp/canvasdiff-shoot}
media="$repo/media"

scenes=("$@")
[ ${#scenes[@]} -gt 0 ] || scenes=(hero live compare sidebar lenses keys)

rasterize() { # <scene-dir>  -> pngs next to the svgs
  local dir=$1
  while read -r _ file; do
    rsvg-convert -o "$dir/${file%.svg}.png" "$dir/$file"
  done < "$dir/manifest.txt"
}

first_png() { # <scene-dir> <name>  (anchored: "unstaged" must not match "staged")
  local dir=$1 name=$2
  awk -v n="-$name.svg" 'index($2, n) {print $2; exit}' "$dir/manifest.txt" \
    | sed 's/\.svg$/.png/' | sed "s|^|$dir/|"
}

for scene in "${scenes[@]}"; do
  dir="$work/$scene"
  rm -rf "$dir"
  mkdir -p "$dir"
  bash "$shoot_dir/fixture.sh" "$work/fixture-$scene" >/dev/null
  nvim --headless --clean -l "$shoot_dir/shoot.lua" \
    "$scene" "$work/fixture-$scene" "$dir"
  rasterize "$dir"

  case "$scene" in
    hero)
      cp "$(first_png "$dir" hero)" "$media/hero.png"
      ;;
    live)
      # Per-frame delays (centiseconds) come straight from the manifest.
      args=()
      while read -r delay file; do
        args+=(-delay "$delay" "$dir/${file%.svg}.png")
      done < "$dir/manifest.txt"
      magick "${args[@]}" -loop 0 -layers optimize "$media/01-live-edit.gif"
      ;;
    compare)
      cp "$(first_png "$dir" compare)" "$media/02-compare.png"
      ;;
    sidebar)
      magick "$(first_png "$dir" folded)" "$(first_png "$dir" jumped)" \
        +smush 24 -background '#1b1d2b' "$media/03-sidebar-fold-jump.png"
      ;;
    lenses)
      magick "$(first_png "$dir" all)" "$(first_png "$dir" unstaged)" \
        "$(first_png "$dir" staged)" -smush 18 -background '#1b1d2b' \
        "$media/04-lenses.png"
      ;;
    keys)
      magick "$(first_png "$dir" cheatsheet)" "$(first_png "$dir" compare-picker)" \
        "$(first_png "$dir" checkout)" +smush 24 -background '#1b1d2b' \
        "$media/05-keys.png"
      ;;
  esac
  echo "done: $scene"
done
