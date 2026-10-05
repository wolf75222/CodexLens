#!/usr/bin/env python3
"""Add Git-object version cases to a NEW anonymous corpus. Never reads real Codex data."""
import argparse, hashlib, importlib.util, json, os, subprocess
from pathlib import Path

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--events', type=int, default=12000)
    args = parser.parse_args()
    base_path = Path(__file__).with_name('create-native-corpus-v06.py')
    spec = importlib.util.spec_from_file_location('lens_fixture', base_path)
    base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
    base.create(args.output, args.events)
    output = args.output.absolute(); manifest_path = output / 'corpus-manifest.json'
    manifest = json.loads(manifest_path.read_text()); repo = Path(manifest['repository']); alpha = Path(manifest['worktrees']['alpha'])
    def object_name(text, write=False):
        env = {'PATH':'/usr/bin:/bin', 'GIT_CONFIG_NOSYSTEM':'1','GIT_CONFIG_GLOBAL':'/dev/null','GIT_TERMINAL_PROMPT':'0'}
        result = subprocess.run(['/usr/bin/git','-c','core.hooksPath=/dev/null','hash-object',*(['-w'] if write else []),'--stdin'], input=text.encode(), cwd=repo, env=env, capture_output=True, check=True)
        return result.stdout.decode().strip()
    before = 'struct Versioned {\n    static let value = "before action"\n    static let unicode = "café 東京"\n}\n'
    after = before.replace('before action', 'after cited by trace')
    reconstructed = before.replace('before action', 'reconstructed target')
    old = object_name(before, True); new = object_name(after, True); derived = object_name(reconstructed)
    current = before.replace('before action', 'manual current edit')
    (alpha / 'src/Versioned.swift').write_text(current)
    def patch(target, value):
        return f'diff --git a/src/Versioned.swift b/src/Versioned.swift\nindex {old}..{target} 100644\n--- a/src/Versioned.swift\n+++ b/src/Versioned.swift\n@@ -1,4 +1,4 @@\n struct Versioned {{\n-    static let value = "before action"\n+    static let value = "{value}"\n     static let unicode = "café 東京"\n }}\n'
    rollout = Path(manifest['rollouts'][base.ROOT]['path'])
    ms = manifest['lastRootTimestampMilliseconds'] + 100
    entries = []
    for ident, target, value, status in [('qa-version-blobs',new,'after cited by trace','completed'),('qa-version-reconstruction',derived,'reconstructed target','completed'),('qa-version-declined',new,'after cited by trace','declined')]:
        entries.append({'timestamp':base.stamp(ms),'type':'event_msg','payload':{'type':'item_completed','item':{'type':'fileChange','id':ident,'cwd':str(alpha),'status':status,'changes':[{'path':'src/Versioned.swift','kind':{'type':'update'},'diff':patch(target,value)}]}}})
        ms += 100
    with rollout.open('ab') as stream:
        for entry in entries: stream.write(base.encoded(entry) + b'\n')
    data = rollout.read_bytes(); recorded = manifest['rollouts'][base.ROOT]
    recorded['sha256'] = base.digest(data); recorded['bytes'] = len(data); recorded['rawRecords'] += len(entries)
    manifest['expected']['familyRawRecordCount'] += len(entries)
    manifest['lastRootTimestampMilliseconds'] = ms - 100
    manifest['versionCases'] = {'path':'src/Versioned.swift','beforeObject':old,'afterObject':new,'reconstructedObjectAbsentInGit':derived,'currentFileSHA256':base.digest(current.encode()),'recordedItemIDs':['qa-version-blobs','qa-version-reconstruction','qa-version-declined']}
    manifest['versionGeneratorSHA256'] = base.digest(Path(__file__).read_bytes())
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(manifest_path)

if __name__ == '__main__': main()
