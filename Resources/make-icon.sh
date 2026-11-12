#!/bin/zsh
# Genera AppIcon.icns a partir de AppIcon.svg (requiere rsvg-convert: brew install librsvg)
set -euo pipefail
cd "$(dirname "$0")"
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s AppIcon.svg -o "$SET/icon_${s}x${s}.png"
  rsvg-convert -w $((s*2)) -h $((s*2)) AppIcon.svg -o "$SET/icon_${s}x${s}@2x.png"
done
iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$(dirname "$SET")"
echo "AppIcon.icns generado"
