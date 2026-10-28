#!/bin/zsh
# Renders the app icon (design/app-icon-d6.svg, concept "D6 · Frost Mono") into the asset catalog:
# the 1024 px opaque AppIcon and a 512 px AppLogo used inside the app (Settings header).
# Needs librsvg: brew install librsvg
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/design/app-icon-d6.svg"
ASSETS="$ROOT/DocSnap/Resources/Assets.xcassets"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rsvg-convert -w 1024 -h 1024 "$SVG" -o "$TMP/icon.png"
swift "$ROOT/scripts/flatten_png.swift" "$TMP/icon.png" "$ASSETS/AppIcon.appiconset/AppIcon.png"
mkdir -p "$ASSETS/AppLogo.imageset"
swift "$ROOT/scripts/flatten_png.swift" "$TMP/icon.png" "$ASSETS/AppLogo.imageset/AppLogo.png" 512
cat > "$ASSETS/AppLogo.imageset/Contents.json" <<'JSON'
{
  "images" : [ { "filename" : "AppLogo.png", "idiom" : "universal" } ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "preserves-vector-representation" : false }
}
JSON
sips -g pixelWidth -g pixelHeight -g hasAlpha "$ASSETS/AppIcon.appiconset/AppIcon.png" | tail -3
