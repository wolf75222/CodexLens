#!/usr/bin/env python3
"""Dedicated synthetic passive-history corpus. Never reads real Codex data or runs recorded tools/hooks."""
import argparse
import datetime
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--events', type=int, default=12000)
    args = parser.parse_args()
    assert str(args.output.absolute()).startswith('/private/tmp/') and not args.output.exists()
    path = Path(__file__).with_name('create-version-corpus-v18.py')
    spec = importlib.util.spec_from_file_location('versions', path)
    versions = importlib.util.module_from_spec(spec); spec.loader.exec_module(versions)
    saved = sys.argv
    try:
        sys.argv = [str(path), '--output', str(args.output), '--events', str(args.events)]
        versions.main()
    finally:
        sys.argv = saved
    base_path = Path(__file__).with_name('create-native-corpus-v06.py')
    spec = importlib.util.spec_from_file_location('fixture', base_path)
    base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
    manifest_path = args.output / 'corpus-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    root, child = manifest['rootID'], manifest['childID']
    alpha, beta = manifest['worktrees']['alpha'], manifest['worktrees']['beta']
    start = manifest['lastRootTimestampMilliseconds'] + 100
    records = {root: [], child: []}

    def record(owner, offset, typ, payload):
        records[owner].append({'timestamp': base.stamp(start + offset), 'type': typ, 'payload': payload})

    def epoch(offset):
        return int(datetime.datetime.fromisoformat(base.stamp(start + offset).replace('Z', '+00:00')).timestamp() * 1000)

    def counts(total, inp=0, out=0):
        return {'input_tokens': inp, 'cached_input_tokens': 0, 'cache_write_input_tokens': 0,
                'output_tokens': out, 'reasoning_output_tokens': 0, 'total_tokens': total}

    def usage(owner, offset, total, last, inp=0, out=0):
        record(owner, offset, 'event_msg', {'type': 'token_count', 'info': {
            'total_token_usage': counts(total, total), 'last_token_usage': counts(last, inp, out), 'model_context_window': 128000}})

    record(root, 0, 'turn_context', {'turn_id': 'qa-context-root', 'cwd': alpha})
    request = {'thread_id': root, 'turn_id': 'qa-context-root', 'response_id': 'qa-provider-response',
               'usage': counts(6000, 4000, 2000), 'thread_token_usage': counts(20000, 16000, 4000)}
    record(root, 100, 'token_usage_record', request)
    record(root, 150, 'token_usage_record', request)  # exact response mirror, not another charge
    usage(root, 200, 20000, 6000, 4000, 2000)
    record(root, 300, 'event_msg', {'type': 'item_started', 'thread_id': root, 'turn_id': 'qa-context-root',
                                  'item': {'type': 'ContextCompaction', 'id': 'qa-root-compaction'}, 'started_at_ms': epoch(300)})
    checkpoint = {'message': '', 'window_id': 'qa-window-root', 'compaction_response_id': 'qa-compact-response',
                  'replacement_history': [{'type': 'compaction', 'id': 'qa-opaque-context', 'encrypted_content': 'SYNTHETIC_OPAQUE_NOT_A_SUMMARY'},
                      {'type': 'message', 'role': 'user', 'content': [{'type': 'input_text', 'text': 'Texte conservé de fixture : distinguer preuves et inconnues.'}]}],
                  'latest_token_usage_record': request}
    record(root, 400, 'compacted', checkpoint)
    usage(root, 500, 20000, 1800)  # rendered estimate in known checkpoint/completion bracket
    record(root, 600, 'event_msg', {'type': 'item_completed', 'thread_id': root, 'turn_id': 'qa-context-root',
                                  'item': {'type': 'ContextCompaction', 'id': 'qa-root-compaction'},
                                  'started_at_ms': epoch(300), 'completed_at_ms': epoch(600)})
    record(root, 650, 'event_msg', {'type': 'context_compacted'})
    record(root, 700, 'response_item', {'type': 'function_call', 'name': 'send_message', 'call_id': 'qa-message-send',
        'arguments': json.dumps({'target': '/root/beta-reader', 'message': 'Inspecter la version de src/Versioned.swift dans Beta et rapporter les preuves.'})})
    record(root, 800, 'response_item', {'type': 'function_call_output', 'call_id': 'qa-message-send', 'output': ''})
    record(root, 900, 'response_item', {'type': 'compaction', 'id': 'qa-opaque-context', 'encrypted_content': 'SYNTHETIC_OPAQUE_NOT_A_SUMMARY'})
    record(root, 1700, 'compacted', {'message': 'Texte conservé de fixture ; début et fin non enregistrés.', 'window_id': 'qa-window-root-2'})
    record(root, 1800, 'event_msg', {'type': 'item_completed', 'item': {'type': 'Plan', 'id': 'qa-recorded-plan',
        'text': 'Plan enregistré de fixture : lire les preuves, comparer les versions, signaler les limites.'}})

    record(child, 0, 'turn_context', {'turn_id': 'qa-context-child', 'cwd': beta})
    record(child, 850, 'inter_agent_communication_metadata', {'trigger_turn': False})
    message = 'Message Type: MESSAGE\nTask name: /root/beta-reader\nSender: /root\nPayload:\nInspecter la version de src/Versioned.swift dans Beta et rapporter les preuves.'
    record(child, 860, 'response_item', {'type': 'agent_message', 'id': 'qa-delivered-message', 'author': '/root',
        'recipient': '/root/beta-reader', 'content': [{'type': 'input_text', 'text': message}]})
    record(child, 870, 'inter_agent_communication', {'id': 'qa-delivered-message', 'author': '/root',
        'recipient': '/root/beta-reader', 'other_recipients': [], 'content': message, 'trigger_turn': False})

    before = 'struct Versioned {\n    static let value = "before action"\n    static let unicode = "café 東京"\n}\n'
    after = before.replace('before action', 'child recorded version')
    following = before.replace('before action', 'change after recorded test')
    environment = {'PATH': '/usr/bin:/bin', 'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0'}
    def object_name(text):
        return subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', 'hash-object', '-w', '--stdin'],
            cwd=manifest['repository'], input=text.encode(), env=environment, capture_output=True, check=True).stdout.decode().strip()
    old, new, later = map(object_name, [before, after, following])
    (Path(beta) / 'src/Versioned.swift').write_text(before.replace('before action', 'manual beta current state'))
    def change(owner, offset, ident, old_sha, new_sha, old_text, new_text, beginning, ending):
        patch = f'diff --git a/src/Versioned.swift b/src/Versioned.swift\nindex {old_sha}..{new_sha} 100644\n--- a/src/Versioned.swift\n+++ b/src/Versioned.swift\n@@ -1,4 +1,4 @@\n struct Versioned {{\n-    static let value = "{old_text}"\n+    static let value = "{new_text}"\n     static let unicode = "café 東京"\n }}\n'
        record(owner, offset, 'event_msg', {'type': 'item_completed', 'started_at_ms': epoch(beginning), 'completed_at_ms': epoch(ending),
            'item': {'type': 'fileChange', 'id': ident, 'cwd': beta, 'status': 'completed',
                     'changes': [{'path': 'src/Versioned.swift', 'kind': {'type': 'update'}, 'diff': patch}]}})
    change(child, 1000, 'qa-child-context-diff', old, new, 'before action', 'child recorded version', 900, 1000)
    record(child, 1100, 'response_item', {'type': 'function_call', 'name': 'exec_command', 'call_id': 'qa-context-test',
        'arguments': json.dumps({'cmd': 'swift test', 'workdir': beta})})
    record(child, 1200, 'response_item', {'type': 'function_call_output', 'call_id': 'qa-context-test',
        'output': 'Process exited with code 0\nSynthetic recorded test result; no test command was executed by this generator.'})
    change(child, 1400, 'qa-change-after-test', new, later, 'child recorded version', 'change after recorded test', 1300, 1400)
    change(root, 1350, 'qa-overlapping-root-change', old, new, 'before action', 'child recorded version', 1250, 1350)
    record(child, 1500, 'captured_hook_input', {'hook_event_name': 'PreCompact', 'session_id': root, 'agent_id': child,
        'turn_id': 'qa-context-child', 'trigger': 'auto'})  # synthetic optional capture, never an installed hook
    record(child, 1550, 'event_msg', {'type': 'item_started', 'item': {'type': 'ContextCompaction', 'id': 'qa-child-compaction'}})
    record(child, 1600, 'compacted', {'message': '', 'window_id': 'qa-window-child',
        'replacement_history': [{'type': 'compaction', 'encrypted_content': 'SYNTHETIC_CHILD_OPAQUE'}]})
    record(child, 1650, 'event_msg', {'type': 'item_completed', 'item': {'type': 'ContextCompaction', 'id': 'qa-child-compaction'}, 'completed_at_ms': 0})
    record(child, 1900, 'response_item', {'type': 'agent_message', 'id': 'qa-opaque-message', 'author': '/root',
        'recipient': '/root/beta-reader', 'content': [{'type': 'encrypted_content', 'encrypted_content': 'SYNTHETIC_OPAQUE_MESSAGE'}]})

    for owner, entries in records.items():
        rollout = Path(manifest['rollouts'][owner]['path'])
        with rollout.open('ab') as stream:
            for entry in entries: stream.write(base.encoded(entry) + b'\n')
        info = manifest['rollouts'][owner]; data = rollout.read_bytes()
        info.update(sha256=base.digest(data), bytes=len(data), rawRecords=info['rawRecords'] + len(entries))
        manifest['expected']['familyRawRecordCount'] += len(entries)
    manifest['lastRootTimestampMilliseconds'] = start + 1900
    manifest['contextCases'] = {'identifiedCompactions': 3, 'rootCompactionID': 'qa-root-compaction',
        'childCompactionID': 'qa-child-compaction', 'deliveredMessageID': 'qa-delivered-message',
        'childDiffID': 'qa-child-context-diff', 'testCallID': 'qa-context-test', 'beforeObject': old, 'afterObject': new,
        'followingObject': later, 'hookInputIsSyntheticOptionalCapture': True,
        'recordedTestCommandWasNeverExecuted': True, 'sentAndDeliveredMessageNotLinkedByTextEquality': True}
    manifest['contextGeneratorSHA256'] = base.digest(Path(__file__).read_bytes())
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(manifest_path)


if __name__ == '__main__': main()
