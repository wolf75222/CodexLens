#!/bin/bash
# Real updater qualification on new, owned fixture bundles only. No live app,
# production update key, observed data or global Codex configuration is used.
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 "$project_dir/scripts/verify_updates.py" "$@"
