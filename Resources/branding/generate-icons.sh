#!/usr/bin/env bash
#
# Regenerate the Regatta app icon + in-app logo PNGs from the source SVG masters.
#
# Pipeline:
#   1. Rasterize the 1024x1024 master SVGs (light + dark) with cairosvg.
#   2. Downscale every required AppIcon.appiconset size with `sips`.
#   3. Refresh the AppIconLight / AppIconDark imagesets (1024px dock-tile logo).
#
# Requirements: cairosvg (pip), sips (macOS built-in).
#
# Usage:  Resources/branding/generate-icons.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRANDING="$REPO_ROOT/Resources/branding"
APPICONSET="$REPO_ROOT/Assets.xcassets/AppIcon.appiconset"
DEBUG_APPICONSET="$REPO_ROOT/Assets.xcassets/AppIcon-Debug.appiconset"
NIGHTLY_APPICONSET="$REPO_ROOT/Assets.xcassets/AppIcon-Nightly.appiconset"
LIGHT_IMAGESET="$REPO_ROOT/Assets.xcassets/AppIconLight.imageset"
DARK_IMAGESET="$REPO_ROOT/Assets.xcassets/AppIconDark.imageset"

LIGHT_SVG="$BRANDING/regatta-icon-light.svg"
DARK_SVG="$BRANDING/regatta-icon-dark.svg"
DEV_SVG="$BRANDING/regatta-icon-dev.svg"
NIGHTLY_SVG="$BRANDING/regatta-icon-nightly.svg"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> Rasterizing 1024px masters"
python3 - "$LIGHT_SVG" "$DARK_SVG" "$DEV_SVG" "$NIGHTLY_SVG" "$WORK" <<'PY'
import sys, cairosvg
light, dark, dev, nightly, work = sys.argv[1:6]
cairosvg.svg2png(url=light,   write_to=f"{work}/master-light.png",   output_width=1024, output_height=1024)
cairosvg.svg2png(url=dark,    write_to=f"{work}/master-dark.png",    output_width=1024, output_height=1024)
cairosvg.svg2png(url=dev,     write_to=f"{work}/master-dev.png",     output_width=1024, output_height=1024)
cairosvg.svg2png(url=nightly, write_to=f"{work}/master-nightly.png", output_width=1024, output_height=1024)
PY

# size (px) -> appiconset filename (without _dark suffix)
declare -a SIZES=(
  "16:16.png"
  "32:16@2x.png"
  "32:32.png"
  "64:32@2x.png"
  "128:128.png"
  "256:128@2x.png"
  "256:256.png"
  "512:256@2x.png"
  "512:512.png"
  "1024:512@2x.png"
)

emit() { # <master> <px> <outfile>
  sips -s format png -z "$2" "$2" "$1" --out "$3" >/dev/null
}

echo "==> Generating AppIcon.appiconset sizes"
for entry in "${SIZES[@]}"; do
  px="${entry%%:*}"
  name="${entry##*:}"
  emit "$WORK/master-light.png" "$px" "$APPICONSET/$name"
  dark_name="${name%.png}_dark.png"
  emit "$WORK/master-dark.png" "$px" "$APPICONSET/$dark_name"
done

# Debug + Nightly variants: same 10 sizes, single (light) appearance, no _dark files.
echo "==> Generating AppIcon-Debug.appiconset sizes"
for entry in "${SIZES[@]}"; do
  px="${entry%%:*}"; name="${entry##*:}"
  emit "$WORK/master-dev.png" "$px" "$DEBUG_APPICONSET/$name"
done

echo "==> Generating AppIcon-Nightly.appiconset sizes"
for entry in "${SIZES[@]}"; do
  px="${entry%%:*}"; name="${entry##*:}"
  emit "$WORK/master-nightly.png" "$px" "$NIGHTLY_APPICONSET/$name"
done

echo "==> Refreshing in-app logo imagesets (1024px)"
cp "$WORK/master-light.png" "$LIGHT_IMAGESET/AppIconLight.png"
cp "$WORK/master-dark.png"  "$DARK_IMAGESET/AppIconDark.png"

echo "==> Done. Generated production ($((${#SIZES[@]} * 2))) + Debug (${#SIZES[@]}) + Nightly (${#SIZES[@]}) appiconset PNGs + 2 imageset PNGs."
