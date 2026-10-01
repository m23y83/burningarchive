#!/bin/bash
# Renders the icon and packs AppIcon.icns. Usage: scripts/make-icns.sh <out-dir>
set -euo pipefail
OUT="${1:-build}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swift "$(dirname "$0")/make-icon.swift" "$WORK/icon_1024.png" >/dev/null
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$WORK/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p "$OUT"
iconutil -c icns "$SET" -o "$OUT/AppIcon.icns"
cp "$WORK/icon_1024.png" "$OUT/AppIcon.png"
echo "Wrote $OUT/AppIcon.icns"
