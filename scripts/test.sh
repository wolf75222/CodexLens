#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
scratch_dir="${LENS_BUILD_DIR:-$project_dir/.build}"
# Forward SwiftPM options, e.g. -c release when disk space is constrained.
swift test --package-path "$project_dir" --scratch-path "$scratch_dir" "$@"
