#!/usr/bin/env python3
"""Create disposable session-curve inputs. Never reads Codex data or executes log tools."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--events', type=int, default=600)
    args = parser.parse_args()
    output = args.output.absolute()
    if not str(output).startswith('/private/tmp/') or output != output.resolve():
        raise SystemExit('A new, unaliased /private/tmp/ output is required.')
    if output.exists() or output.is_symlink() or args.events < 100:
        raise SystemExit('Refusing an existing output or fewer than 100 events.')
    script_dir = Path(__file__).parent
    origin_path = script_dir / 'create-origin-corpus-v21.py'
    origin = load_module('lens_curves_origin_v21', origin_path)
    saved = sys.argv
    try:
        sys.argv = [str(origin_path), '--output', str(output), '--events', str(args.events)]
        origin.main()
    finally:
        sys.argv = saved
    base = load_module('lens_curves_native_v06', script_dir / 'create-native-corpus-v06.py')
    manifest_path = output / 'corpus-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    root = manifest['rootID']
    path = Path(manifest['rollouts'][root]['path'])
    if not path.is_relative_to(output):
        raise SystemExit('Generated source escaped its disposable corpus.')
    stream = base.Stream(start=manifest['lastRootTimestampMilliseconds'] + 100)
    dated_calls = ['qa-curves-mcp-lookup', 'qa-curves-mcp-failed']
    stream.call(dated_calls[0], 'mcp__lens_fixture__lookup', {'query': 'anonymous symbol'})
    stream.result(dated_calls[0], json.dumps({'matches': ['src/Same.swift'], 'fixture': True}))
    stream.call(dated_calls[1], 'mcp__lens_fixture__lookup', {'query': 'missing anonymous symbol'})
    error = stream.result(dated_calls[1], 'Recorded fixture failure: symbol unavailable.')
    error['payload']['is_error'] = True
    stream.call('qa-curves-wait', 'wait', {'cell_id': 'anonymous-fixture-cell'})
    stream.result('qa-curves-wait', 'Recorded wait ended. No wait or tool was executed.')
    # Missing dates remain unknown; the fixture does not borrow a nearby timestamp.
    undated = 'qa-curves-mcp-undated'
    stream.records += [
        {'type': 'response_item', 'payload': {'type': 'function_call', 'call_id': undated,
            'name': 'mcp__lens_fixture__lookup', 'arguments': '{"query":"undated fixture"}'}},
        {'type': 'response_item', 'payload': {'type': 'function_call_output', 'call_id': undated,
            'output': 'Recorded undated output. Timestamp unavailable.'}},
    ]
    with path.open('ab') as target:
        for record in stream.records:
            target.write(base.encoded(record) + b'\n')
        target.write(b'{"type":"response_item","payload":')
    data = path.read_bytes()
    manifest['rollouts'][root].update(sha256=digest(data), bytes=len(data),
        rawRecords=manifest['rollouts'][root]['rawRecords'] + len(stream.records))
    manifest['expected']['familyRawRecordCount'] += len(stream.records)
    manifest['lastRootTimestampMilliseconds'] = stream.milliseconds - 100
    # Same thread ID, explicitly different observation source. Created before inspection.
    alternate_home = output / 'alternate-codex-home'
    alternate = alternate_home / 'sessions/2026/10/01' / path.name
    alternate.parent.mkdir(parents=True)
    alternate.write_bytes(data)
    manifest['curvesCases'] = {
        'datedMCPCallIDs': dated_calls, 'undatedMCPCallID': undated,
        'expectedMCPCount': 3, 'expectedDatedMCPCount': 2, 'expectedUnplottedMCPCount': 1,
        'failedMCPCallID': dated_calls[1], 'waitCallID': 'qa-curves-wait',
        'alternateHome': str(alternate_home), 'alternateRootRollout': str(alternate),
        'alternateRootSHA256': digest(data), 'fixtureToolsWereNeverExecuted': True,
        'sourceSwitchRetainsThreadID': True,
        'partialFinalRecordBytes': len(b'{"type":"response_item","payload":'),
    }
    manifest['curvesGeneratorSHA256'] = digest(Path(__file__).read_bytes())
    manifest['curvesImportedGeneratorSHA256'] = digest(origin_path.read_bytes())
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'manifest': str(manifest_path), 'rootID': root, 'curveMCPCalls': 3}))


if __name__ == '__main__':
    main()
