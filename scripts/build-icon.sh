#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
asset_dir="$project_dir/Assets"
icon_work="$(mktemp -d "${TMPDIR:-/tmp}/codex-lens-icon.XXXXXX")"
trap 'rm -rf "$icon_work"' EXIT
command -v rsvg-convert >/dev/null
command -v python3 >/dev/null
srgb_profile="/System/Library/ColorSync/Profiles/sRGB Profile.icc"
test -r "$srgb_profile"
python3 "$project_dir/scripts/generate-icon.py"
# SVG colors are sRGB. Declare that profile without converting their values.
render_png() {
    local pixels="$1" source="$2" destination="$3"
    rsvg-convert -w "$pixels" -h "$pixels" "$source" -o "$destination"
    /usr/bin/sips --embedProfile "$srgb_profile" "$destination" >/dev/null
}
for variant in Light Dark; do
    name="CodexLens-$variant"
    iconset="$icon_work/$name.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        render_png "$size" "$asset_dir/$name.svg" "$iconset/icon_${size}x${size}.png"
        double=$((size * 2))
        render_png "$double" "$asset_dir/$name.svg" "$iconset/icon_${size}x${size}@2x.png"
    done
    cp "$iconset/icon_512x512.png" "$asset_dir/$name.png"
    /usr/bin/iconutil -c icns "$iconset" -o "$asset_dir/$name.icns"
    python3 "$project_dir/scripts/verify-icon-assets.py" --asset-dir "$asset_dir" --name "$name"
done
# Finder's static bundle icon is dark; the running app chooses its Dock variant.
for extension in svg png icns; do
    cp "$asset_dir/CodexLens-Dark.$extension" "$asset_dir/CodexLens.$extension"
done
