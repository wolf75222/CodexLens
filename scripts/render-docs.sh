#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
work_dir="$(mktemp -d /private/tmp/codex-lens-docs.XXXXXX)"
cleanup() {
    status=$?
    if [[ "$status" == 0 ]]; then rm -rf "$work_dir"; else printf 'Retained failed render diagnostics: %s\n' "$work_dir" >&2; fi
}
trap cleanup EXIT
python3 "$project_dir/scripts/create-origin-corpus-v21.py" --output "$work_dir/corpus" --events 600
zsh "$project_dir/scripts/verify-design-v07.sh" --source-root "$project_dir" \
    --output "$work_dir/renders" --corpus "$work_dir/corpus" \
    --entrypoint PublicDocsMain.swift --after-source-freeze --run
mkdir -p "$project_dir/docs/images"
for view in activity diff chat; do cp "$work_dir/renders/$view.png" "$project_dir/docs/images/$view.png"; done
python3 - "$project_dir" "$work_dir/renders" <<'PY'
from pathlib import Path
import hashlib, json, sys
root, output = map(Path, sys.argv[1:])
manifest = json.loads((output/'native-design-v07-source-manifest.json').read_text())
receipt = json.loads((output/'native-design-v07-receipt.json').read_text())
public = {'method': receipt['method'], 'syntheticSession': True,
          'modelRequests': 0, 'accountRequests': 0,
          'sourceHashes': {name: value['sha256'] for name, value in manifest['files'].items()},
          'images': {name: hashlib.sha256((root/'docs/images'/name).read_bytes()).hexdigest() for name in receipt['renders']}}
(root/'docs/images/provenance.json').write_text(json.dumps(public, indent=2)+'\n')
PY
