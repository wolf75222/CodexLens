#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="${LENS_BUILD_DIR:-$project_dir/.build}"
app_dir="${LENS_APP_PATH:-$project_dir/dist/Codex Lens.app}"
configuration="release"
profile=false
case "${1:-}" in
    "") ;;
    --debug) configuration="debug" ;;
    --profile) profile=true ;;
    *) printf 'Usage: %s [--debug|--profile]\n' "$0" >&2; exit 2 ;;
esac
build_args=(--package-path "$project_dir" --scratch-path "$scratch_dir" -c "$configuration")
if $profile; then build_args+=(-Xswiftc -g); fi
swift build "${build_args[@]}"
bin_dir="$(swift build "${build_args[@]}" --show-bin-path)"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$bin_dir/CodexLens" "$app_dir/Contents/MacOS/CodexLens"
cp "$project_dir/Support/Info.plist" "$app_dir/Contents/Info.plist"
python3 "$project_dir/scripts/sparkle_bundle.py" embed --artifacts "$scratch_dir/artifacts" --app "$app_dir"
cp "$project_dir/Assets/CodexLens.icns" "$app_dir/Contents/Resources/CodexLens.icns"
cp "$project_dir/Assets/CodexLens.svg" "$app_dir/Contents/Resources/CodexLens.svg"
for variant in Light Dark; do
    cp "$project_dir/Assets/CodexLens-$variant.icns" "$app_dir/Contents/Resources/"
    cp "$project_dir/Assets/CodexLens-$variant.svg" "$app_dir/Contents/Resources/"
done
mkdir -p "$app_dir/Contents/Resources/Localizations"
cp "$project_dir/Assets/Localizations/en.json" "$app_dir/Contents/Resources/Localizations/en.json"
mkdir -p "$app_dir/Contents/Resources/Help"
cp "$project_dir/Assets/Help/"*.png "$app_dir/Contents/Resources/Help/"
cp "$project_dir/THIRD_PARTY_NOTICES.md" "$app_dir/Contents/Resources/THIRD_PARTY_NOTICES.txt"
if [[ -f "$project_dir/LICENSE" ]]; then cp "$project_dir/LICENSE" "$app_dir/Contents/Resources/LICENSE.txt"; fi
python3 - "$project_dir" "$app_dir" <<'PY'
import json, plistlib, subprocess, sys
from pathlib import Path
root, app = map(Path, sys.argv[1:])
def command(args):
    result = subprocess.run(args, cwd=root, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else None
info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
revision = command(['git', 'rev-parse', 'HEAD'])
data = {'schemaVersion': 1, 'version': info['CFBundleShortVersionString'],
        'build': info['CFBundleVersion'], 'sourceCommit': revision,
        'dirty': revision is None or bool(command(['git', 'status', '--porcelain'])),
        'swift': command(['swift', '--version']),
        'sdk': command(['xcrun', '--sdk', 'macosx', '--show-sdk-version'])}
(app/'Contents/Resources/BuildInfo.json').write_text(json.dumps(data, indent=2)+'\n')
PY
xattr -cr "$app_dir"
python3 "$project_dir/scripts/sparkle_bundle.py" runtime --app "$app_dir"
python3 "$project_dir/scripts/sparkle_bundle.py" validate --app "$app_dir"
python3 "$project_dir/scripts/sparkle_bundle.py" sign --app "$app_dir"
if $profile; then
    dsymutil "$app_dir/Contents/MacOS/CodexLens" -o "$app_dir.dSYM"
    dwarfdump --uuid "$app_dir/Contents/MacOS/CodexLens" "$app_dir.dSYM"
fi
printf 'Application: %s\nInspecteur CLI: %s\n' "$app_dir" "$bin_dir/lens-inspect"
