#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$project_dir/Documentation/ICON-v40/native-icon.json}"
work="$(mktemp -d "${TMPDIR:-/tmp}/codex-lens-icon-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$(dirname "$output")"
swiftc -O -g "$project_dir/Sources/CodexLens/LensAppIcon.swift" "$project_dir/Tests/NativeUI/AppIconV40Main.swift" -o "$work/icon-probe"
"$work/icon-probe" "$output" "$project_dir/Assets"
