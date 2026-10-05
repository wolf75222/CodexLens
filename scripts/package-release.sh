#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
release_python="${LENS_RELEASE_PYTHON:-$project_dir/.venv-release/bin/python}"
if [[ ! -x "$release_python" ]]; then
    python3 -m venv "$project_dir/.venv-release"
fi
if ! "$release_python" -c 'import dmgbuild, ds_store, mac_alias' >/dev/null 2>&1; then
    "$release_python" -m pip install --require-hashes -r "$project_dir/scripts/requirements-release.txt"
fi
exec "$release_python" "$project_dir/scripts/package_release.py" "$@"
