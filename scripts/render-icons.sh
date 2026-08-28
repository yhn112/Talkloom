#!/usr/bin/env bash
# Render every tracked icon asset from its canonical vector artwork. Each app-icon size is
# rendered independently to avoid compounding resampling artifacts in the smallest assets.
set -euo pipefail

cd "$(dirname "$0")/.."

app_icon_source="Resources/Brand/TranscriberIcon.svg"
glyph_source="Resources/Brand/OpenRibbon.svg"
app_icon_directory="Resources/Assets.xcassets/AppIcon.appiconset"
menu_bar_directory="Resources/Assets.xcassets/MenuBarIcon.imageset"
recording_icon_directory="Resources/Assets.xcassets/MenuBarRecordingIcon.imageset"

render() {
    local size=$1
    local destination=$2
    sips -s format png -s formatOptions best -z "$size" "$size" \
        "$app_icon_source" --out "$destination" >/dev/null
}

render 1024 Resources/Brand/TranscriberIcon.png

while read -r size filename; do
    render "$size" "$app_icon_directory/$filename"
done <<'SIZES'
16 icon_16x16.png
32 icon_16x16@2x.png
32 icon_32x32.png
64 icon_32x32@2x.png
128 icon_128x128.png
256 icon_128x128@2x.png
256 icon_256x256.png
512 icon_256x256@2x.png
512 icon_512x512.png
1024 icon_512x512@2x.png
SIZES

cp "$glyph_source" "$menu_bar_directory/MenuBarIcon.svg"
sed 's|</svg>|  <circle cx="206" cy="245" r="52" fill="#000000"/>\
</svg>|' "$glyph_source" > "$recording_icon_directory/MenuBarRecordingIcon.svg"

echo "Rendered icon assets from Resources/Brand"
