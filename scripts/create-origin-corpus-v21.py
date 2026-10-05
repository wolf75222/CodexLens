#!/usr/bin/env python3
"""New anonymous history for provenance QA; never executes recorded tools or Codex.

The reviewed v20 generator already imports v18 and v06. This adds native 0.159.2
records and real local Git blobs. Relations expected by QA live in the external
manifest, never in invented cause/justification fields in the JSONL sources.
"""
import argparse
import datetime
import difflib
import importlib.util
import json
from pathlib import Path
import subprocess
import sys


GRANDCHILD = '44444444-4444-4444-8444-444444444444'
FORK = '55555555-5555-4555-8555-555555555555'
GRANDCHILD_PATH = '/root/beta-reader/origin-writer'


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--events', type=int, default=600)
    args = parser.parse_args()
    output = args.output.absolute()
    # No traversal, symlink alias, reused fixture, user Codex home, or repo writes.
    assert str(output).startswith('/private/tmp/') and output == output.resolve()
    assert not output.exists() and not output.is_symlink()
    assert args.events >= 100
    script_dir = Path(__file__).parent
    context_path = script_dir / 'create-context-corpus-v20.py'
    context = load_module('lens_context_fixture_v20', context_path)
    saved = sys.argv
    try:
        sys.argv = [str(context_path), '--output', str(output), '--events', str(args.events)]
        context.main()
    finally:
        sys.argv = saved
    base = load_module('lens_native_fixture_v06', script_dir / 'create-native-corpus-v06.py')
    manifest_path = output / 'corpus-manifest.json'
    manifest = json.loads(manifest_path.read_text())
    root, child = manifest['rootID'], manifest['childID']
    alpha, beta = map(Path, (manifest['worktrees']['alpha'], manifest['worktrees']['beta']))
    repo = Path(manifest['repository'])
    assert repo.is_relative_to(output) and alpha.is_relative_to(output) and beta.is_relative_to(output)
    start = manifest['lastRootTimestampMilliseconds'] + 100
    records = {root: [], child: [], GRANDCHILD: [], FORK: []}
    owned_turns = {root: 'qa-origin-root', child: 'qa-origin-child', GRANDCHILD: 'qa-origin-grandchild', FORK: 'qa-origin-fork'}

    def record(owner, offset, kind, payload):
        # New fixture event environments use one macOS /tmp spelling, including test/results.
        # Historical alias spellings remain separate recorded environments in Lens.
        if isinstance(payload.get('cwd'), str) and payload['cwd'].startswith('/private/tmp/'):
            payload = dict(payload, cwd=payload['cwd'][8:])
        value = {'timestamp': base.stamp(start + offset), 'type': kind, 'payload': payload}
        records[owner].append(value)
        return value

    def epoch(offset):
        return int(datetime.datetime.fromisoformat(base.stamp(start + offset).replace('Z', '+00:00')).timestamp() * 1000)

    def message(owner, offset, ident, role, text):
        return record(owner, offset, 'response_item', {'type': 'message', 'id': ident, 'role': role,
            'content': [{'type': 'input_text' if role in ('user', 'developer') else 'output_text', 'text': text}]})

    def call(owner, offset, ident, name, args, namespace='functions'):
        return record(owner, offset, 'response_item', {'type': 'function_call', 'call_id': ident,
            'name': name, 'namespace': namespace, 'arguments': base.encoded(args).decode()})

    def result(owner, offset, ident, text):
        payload = {'type': 'function_call_output', 'call_id': ident, 'output': text}
        return record(owner, offset, 'response_item', payload)

    def custom_patch(owner, offset, ident, text):
        return record(owner, offset, 'response_item', {'type': 'custom_tool_call',
            'call_id': ident, 'name': 'apply_patch', 'input': text})

    def custom_result(owner, offset, ident, text):
        return record(owner, offset, 'response_item', {'type': 'custom_tool_call_output',
            'call_id': ident, 'output': text})

    def completed(owner, offset, item, beginning=None, ending=None):
        payload = {'type': 'item_completed', 'thread_id': owner, 'turn_id': owned_turns[owner],
                   'item': item, 'completed_at_ms': epoch(ending) if ending is not None else 0}
        if beginning is not None:
            payload['started_at_ms'] = epoch(beginning)
        return record(owner, offset, 'event_msg', payload)

    def reasoning(owner, offset, ident, summary=None, exposed=None, opaque=None):
        payload = {'type': 'reasoning', 'id': ident,
                   'summary': [] if summary is None else [{'type': 'summary_text', 'text': summary}],
                   'encrypted_content': opaque}
        if exposed is not None:
            payload['content'] = [{'type': 'reasoning_text', 'text': exposed}]
        return record(owner, offset, 'response_item', payload)

    environment = {'PATH': '/usr/bin:/bin', 'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_TERMINAL_PROMPT': '0'}

    def blob(text):
        return subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null',
            'hash-object', '-w', '--stdin'], cwd=repo, input=text.encode(), env=environment,
            capture_output=True, check=True).stdout.decode().strip()

    def unified(path, before, after, old, new):
        # Preserve unchanged lines as context, including the Unicode constraint.
        body = ''.join(difflib.unified_diff(before.splitlines(keepends=True),
            after.splitlines(keepends=True), fromfile='a/' + path, tofile='b/' + path))
        return f'diff --git a/{path} b/{path}\nindex {old}..{new} 100644\n' + body

    def observed(owner, offset, ident, paths, status='completed', beginning=None, ending=None):
        return completed(owner, offset, {'type': 'FileChange', 'id': ident, 'status': status,
            'changes': {path: {'type': 'update', 'unified_diff': diff, 'move_path': None}
                        for path, diff in paths.items()}}, beginning, ending)

    # Two source prompts in one root turn, before the existing explicit root→child spawn.
    # They are contextual contributions, not a fabricated per-line cause.
    root_path = Path(manifest['rollouts'][root]['path'])
    root_existing = [json.loads(line) for line in root_path.read_bytes().splitlines()]
    prompt_a = {'timestamp': base.stamp(450), 'type': 'response_item', 'payload': {
        'type': 'message', 'id': 'qa-origin-prompt-primary', 'role': 'user', 'content': [{
            'type': 'input_text', 'text': 'Dans Beta, remplacer la valeur de src/Origin.swift par « recorded grandchild » ; déléguer ce changement et préserver sa version avant/après.'}]}}
    prompt_b = {'timestamp': base.stamp(460), 'type': 'response_item', 'payload': {
        'type': 'message', 'id': 'qa-origin-prompt-constraint', 'role': 'user', 'content': [{
            'type': 'input_text', 'text': 'Précision pour la même demande : préserver le texte Unicode, vérifier ensuite, et distinguer les éditions manuelles concurrentes.'}]}}
    mission_child = 'Lire src/Same.swift dans Beta ; puis déléguer à un enfant le changement borné de src/Origin.swift demandé par l’utilisateur. Préserver les versions et rendre les preuves, sans attribuer le diff manuel à Codex.'
    insertion = next(i for i, value in enumerate(root_existing) if value.get('payload', {}).get('call_id') == 'qa-spawn')
    root_existing[insertion:insertion] = [{'timestamp': base.stamp(440), 'type': 'turn_context',
        'payload': {'turn_id': 'qa-origin-root-prompts', 'cwd': str(alpha)}}, prompt_a, prompt_b]
    for value in root_existing:
        payload = value.get('payload', {})
        if payload.get('call_id') == 'qa-spawn' and payload.get('type') == 'function_call':
            args_value = json.loads(payload['arguments']); args_value['message'] = mission_child
            payload['arguments'] = base.encoded(args_value).decode()
    child_path = Path(manifest['rollouts'][child]['path'])
    child_existing = [json.loads(line) for line in child_path.read_bytes().splitlines()]
    for value in child_existing:
        if value.get('payload', {}).get('id') == 'qa-child-mission':
            value['payload']['content'][0]['text'] = 'Mission reçue : ' + mission_child

    before = 'struct Origin {\n    static let value = "before origin"\n    static let unicode = "café 東京"\n}\n'
    after = before.replace('before origin', 'recorded grandchild')
    parent_after = after.replace('recorded grandchild', 'recorded parent contribution')
    test_after = after.replace('recorded grandchild', 'recorded change after test')
    partial_after = before.replace('before origin', 'partial effect recorded')
    alpha_after = before.replace('before origin', 'recorded alpha homonym')
    old, new, parent_new, following, partial_new, alpha_new = map(blob,
        [before, after, parent_after, test_after, partial_after, alpha_after])
    (beta / 'src/Origin.swift').write_text(before.replace('before origin', 'manual current beta'))
    (alpha / 'src/Origin.swift').write_text(before.replace('before origin', 'manual current alpha'))
    main_diff = unified('src/Origin.swift', before, after, old, new)
    parent_diff = unified('src/Origin.swift', after, parent_after, new, parent_new)
    following_diff = unified('src/Origin.swift', after, test_after, new, following)
    partial_diff = unified('src/Partial.swift', before, partial_after, old, partial_new)
    alpha_diff = unified('src/Origin.swift', before, alpha_after, old, alpha_new)
    (beta / 'src/Partial.swift').write_text(before.replace('before origin', 'manual current partial'))

    record(root, 0, 'turn_context', {'turn_id': owned_turns[root], 'cwd': str(alpha)})
    reasoning(root, 40, 'qa-origin-root-unrelated-summary',
        summary='Résumé exposé de fixture : comparer les noms de ressources jointes. Ce texte ne déclare pas la justification du patch Origin.swift.')
    # Same path, another worktree and another producer: it is a separate file.
    observed(root, 950, 'qa-origin-alpha-homonym', {'src/Origin.swift': alpha_diff}, beginning=900, ending=950)
    call(root, 1600, 'qa-origin-send-without-reception', 'send_message',
        {'target': GRANDCHILD, 'message': 'Correction proposée : ne pas toucher src/ManualOnly.swift ; rendre les preuves disponibles.'}, 'agents')
    result(root, 1610, 'qa-origin-send-without-reception', '')
    # No recipient copy, no model-request inclusion, no invented acknowledgement.

    record(child, 0, 'turn_context', {'turn_id': owned_turns[child], 'cwd': str(beta)})
    message(child, 100, 'qa-origin-parent-intent', 'assistant',
        'Je transmets le changement de src/Origin.swift à un sous-agent, en conservant la version et la contrainte Unicode. Cette déclaration ne prouve pas l’application de chaque consigne.')
    completed(child, 200, {'type': 'Plan', 'id': 'qa-origin-parent-plan',
        'text': 'Lire la version Beta ; déléguer Origin.swift ; inspecter les résultats et les limites.'}, ending=200)
    inherited_call = call(child, 300, 'qa-origin-parent-read', 'exec_command',
        {'cmd': 'cat src/Origin.swift', 'workdir': str(beta)})
    inherited_result = result(child, 400, 'qa-origin-parent-read', before)
    mission_grandchild = 'Dans Beta uniquement, remplacer la valeur de src/Origin.swift par « recorded grandchild ». Conserver café 東京, les versions avant/après et les preuves du patch. Vérifier ensuite ; ne pas confondre le contenu actuel ou Alpha avec la version historique.'
    call(child, 500, 'qa-origin-spawn-grand', 'spawn_agent',
        {'task_name': 'origin-writer', 'message': mission_grandchild, 'cwd': str(beta), 'fork_turns': 'all'}, 'agents')
    result(child, 510, 'qa-origin-spawn-grand', base.encoded({
        'agent_id': GRANDCHILD, 'task_name': GRANDCHILD_PATH}).decode())
    observed(child, 1020, 'qa-origin-parent-same-file', {'src/Origin.swift': parent_diff}, beginning=920, ending=1020)
    message(child, 1700, 'qa-origin-parent-later-statement', 'assistant',
        'Déclaration ultérieure de fixture : la valeur Beta a reçu une contribution de parent enregistrée. Ce texte reçu après le patch n’est pas sa justification antérieure.')

    # A copied prefix is model context, not a second execution owned by the child.
    # Include the parent's captured prefix through its read result. Its native
    # calls, earlier file changes and compaction must not become new child activity.
    inherited_prefix = child_existing + records[child][:5]
    record(GRANDCHILD, 600, 'turn_context', {'turn_id': owned_turns[GRANDCHILD], 'cwd': str(beta)})
    message(GRANDCHILD, 610, 'qa-origin-grand-mission', 'user', mission_grandchild)
    reasoning(GRANDCHILD, 620, 'qa-origin-summary-readable',
        summary='Résumé exposé de fixture : conserver la ligne Unicode et limiter le patch au fichier Beta demandé. Le résumé ne constitue pas une transcription exhaustive de pensée.')
    reasoning(GRANDCHILD, 630, 'qa-origin-summary-empty', summary='')
    reasoning(GRANDCHILD, 640, 'qa-origin-summary-opaque', opaque='SYNTHETIC_OPAQUE_REASONING_NOT_A_SUMMARY')
    # No reasoning item for qa-origin-absent-turn: its production is unknown.
    reasoning(GRANDCHILD, 690, 'qa-origin-unrelated-nearby',
        summary='Résumé temporellement proche : vérifier le nom de la pièce jointe PNG. Aucun lien au patch n’est déclaré.')
    completed(GRANDCHILD, 700, {'type': 'AgentMessage', 'id': 'qa-origin-declared-motive',
        'phase': 'commentary', 'content': [{'type': 'Text', 'text':
            'Motif déclaré pour le patch qa-origin-grand-patch : appliquer la mission Beta en préservant la ligne Unicode. Les deux demandes du parent sont du contexte enregistré ; leur effet ligne par ligne n’est pas démontré.'}]}, ending=700)
    requested = ('*** Begin Patch\n*** Update File: src/Origin.swift\n@@\n'
        '-    static let value = "before origin"\n+    static let value = "recorded grandchild"\n*** End Patch')
    custom_patch(GRANDCHILD, 800, 'qa-origin-grand-patch', requested)
    custom_result(GRANDCHILD, 910, 'qa-origin-grand-patch',
        'Success. Updated the following files:\nM src/Origin.swift\nSynthetic recorded result; the generator never executes apply_patch.')
    observed(GRANDCHILD, 920, 'qa-origin-grand-patch', {'src/Origin.swift': main_diff}, beginning=800, ending=910)
    call(GRANDCHILD, 1100, 'qa-origin-grand-test', 'exec_command', {'cmd': 'swift test', 'workdir': str(beta)})
    result(GRANDCHILD, 1200, 'qa-origin-grand-test',
        'Process exited with code 0\nSynthetic successful test trace; swift test was never executed by this generator.')
    observed(GRANDCHILD, 1300, 'qa-origin-after-test-change', {'src/Origin.swift': following_diff}, beginning=1250, ending=1300)
    completed(GRANDCHILD, 1400, {'type': 'Reasoning', 'id': 'qa-origin-late-summary',
        'summary_text': ['Résumé reçu après les actions : cette réception tardive n’établit pas l’instant de décision.'],
        'raw_content': []})
    failed_request = ('*** Begin Patch\n*** Update File: src/Partial.swift\n@@\n'
        '-    static let value = "before origin"\n+    static let value = "partial effect recorded"\n'
        '*** Update File: src/Absent.swift\n@@\n-old\n+new\n*** End Patch')
    custom_patch(GRANDCHILD, 1500, 'qa-origin-failed-partial-patch', failed_request)
    custom_result(GRANDCHILD, 1520, 'qa-origin-failed-partial-patch',
        'Error: file src/Absent.swift was not found. An independently recorded partial effect follows; this result alone does not prove no effect.')
    # A failed FileChange with changes could just describe the attempted patch.
    # Use a separate completed observation instead; no shared tool ID is invented.
    observed(GRANDCHILD, 1530, 'qa-origin-partial-effect-observation', {'src/Partial.swift': partial_diff},
        beginning=1500, ending=1530)
    record(GRANDCHILD, 1800, 'turn_context', {'turn_id': 'qa-origin-absent-turn', 'cwd': str(beta)})
    message(GRANDCHILD, 1810, 'qa-origin-absent-turn-message', 'assistant',
        'Aucun élément de résumé n’est enregistré dans ce tour de fixture ; sa production reste inconnue.')

    generated_before_a = 'let generatedA = "before"\n'
    generated_after_a = 'let generatedA = "recorded generator output"\n'
    generated_before_b = 'let generatedB = "before"\n'
    generated_after_b = 'let generatedB = "recorded generator output"\n'
    gen_old_a, gen_new_a, gen_old_b, gen_new_b = map(blob,
        [generated_before_a, generated_after_a, generated_before_b, generated_after_b])
    (beta / 'src/GeneratedA.swift').write_text('let generatedA = "manual concurrent edit"\n')
    (beta / 'src/GeneratedB.swift').write_text(generated_after_b)
    call(child, 1900, 'qa-origin-generator-call', 'exec_command', {
        'cmd': 'python3 tools/generate-fixture.py --output src/GeneratedA.swift --second src/GeneratedB.swift',
        'workdir': str(beta)})
    result(child, 2000, 'qa-origin-generator-call',
        'Process exited with code 0\nRecorded generator trace only; no script or shell command was executed.')
    # Different ID from the shell call: same period/files do not prove execution linkage.
    observed(child, 2010, 'qa-origin-generator-observation', {
        'src/GeneratedA.swift': unified('src/GeneratedA.swift', generated_before_a, generated_after_a, gen_old_a, gen_new_a),
        'src/GeneratedB.swift': unified('src/GeneratedB.swift', generated_before_b, generated_after_b, gen_old_b, gen_new_b)
    }, beginning=1900, ending=2010)
    message(child, 2100, 'qa-origin-generator-declaration', 'assistant',
        'Déclaration enregistrée : le script qa-origin-generator-call a produit GeneratedA.swift et GeneratedB.swift. La version actuelle de GeneratedA peut inclure une édition manuelle sans trace ; aucun choix explicite de chaque ligne n’est enregistré.')

    # A native fork refers to a physical parent history prefix; it does not replay it.
    # No local copy is fabricated here: history_base preserves its exact byte boundary.
    child_prefix = child_existing + records[child][:5]
    prefix_bytes = b''.join(base.encoded(value) + b'\n' for value in child_prefix)
    message(FORK, 2200, 'qa-origin-fork-own-message', 'user',
        'Question de fork de fixture : consulter le contexte hérité sans refaire la lecture ni le patch.')

    def write(ident, entries, meta=None):
        if meta is None:
            path = Path(manifest['rollouts'][ident]['path'])
        else:
            path = Path(manifest['home']) / 'sessions/2026/10/01' / ('rollout-2026-10-01T12-00-00-' + ident + '.jsonl')
            entries = [{'timestamp': base.stamp(start), 'type': 'session_meta', 'payload': meta}] + entries
        assert path.is_relative_to(output)
        data = b''.join(base.encoded(value) + b'\n' for value in entries)
        path.write_bytes(data)
        manifest['rollouts'][ident] = {'path': str(path), 'sha256': base.digest(data),
            'bytes': len(data), 'rawRecords': len(entries)}

    write(root, root_existing + records[root])
    write(child, child_existing + records[child])
    common_meta = {'session_id': root, 'cwd': str(beta), 'originator': 'codex-lens-anonymous-fixture',
        'cli_version': '0.159.2', 'timestamp': base.stamp(start),
        'git': {'branch': 'qa-beta', 'commit_hash': manifest['baselineGitReference']}}
    grand_meta = dict(common_meta, id=GRANDCHILD, parent_thread_id=child,
        agent_path=GRANDCHILD_PATH, subagent_history_start_ordinal=len(inherited_prefix) + 1,
        source={'subagent': {'thread_spawn': {'parent_thread_id': child, 'depth': 2, 'agent_path': GRANDCHILD_PATH}}})
    write(GRANDCHILD, inherited_prefix + records[GRANDCHILD], grand_meta)
    fork_meta = dict(common_meta, id=FORK, source='cli', forked_from_id=child,
        forked_from_ordinal_exclusive=len(child_prefix),
        history_base={'thread_id': child, 'end_ordinal_exclusive': len(child_prefix),
                      'end_byte_offset': len(prefix_bytes)})
    write(FORK, records[FORK], fork_meta)
    manifest['grandchildID'] = GRANDCHILD
    manifest['forkID'] = FORK
    manifest['expected']['agents'] = [root, child, GRANDCHILD, FORK]
    manifest['expected']['familyRawRecordCount'] = sum(manifest['rollouts'][ident]['rawRecords']
        for ident in manifest['expected']['agents'])
    manifest['lastRootTimestampMilliseconds'] = start + 2200
    manifest['originCases'] = {
        'producerRootID': root, 'producerChildID': child, 'producerGrandchildID': GRANDCHILD,
        'rootPromptsSameTurn': ['qa-origin-prompt-primary', 'qa-origin-prompt-constraint'],
        'rootPromptTurnID': 'qa-origin-root-prompts',
        'rootChildSpawnCallID': 'qa-spawn', 'childGrandchildSpawnCallID': 'qa-origin-spawn-grand',
        'grandchildMissionID': 'qa-origin-grand-mission',
        'nativeProducerParentRelations': {child: root, GRANDCHILD: child},
        'allFamilySessionIDsAreRoot': True,
        'mainPath': 'src/Origin.swift', 'mainEnvironment': str(beta),
        'mainPatchCallID': 'qa-origin-grand-patch', 'mainFileChangeItemID': 'qa-origin-grand-patch',
        'mainBeforeObject': old, 'mainAfterObject': new,
        'mainCurrentSHA256': base.digest((beta / 'src/Origin.swift').read_bytes()),
        'mainCurrentIsHistoricalAfter': False,
        'declaredMotiveID': 'qa-origin-declared-motive',
        'readableSummaryID': 'qa-origin-summary-readable', 'emptySummaryID': 'qa-origin-summary-empty',
        'opaqueSummaryID': 'qa-origin-summary-opaque', 'lateSummaryID': 'qa-origin-late-summary',
        'lateSummaryHasGenerationTime': False, 'absentSummaryTurnID': 'qa-origin-absent-turn',
        'absentSummaryProductionKnown': False, 'unrelatedNearbyReasoningID': 'qa-origin-unrelated-nearby',
        'unrelatedRootReasoningID': 'qa-origin-root-unrelated-summary',
        'parentLaterStatementID': 'qa-origin-parent-later-statement', 'parentPlanID': 'qa-origin-parent-plan',
        'sameFileOtherAgentFileChangeID': 'qa-origin-parent-same-file',
        'sameRelativePathOtherEnvironmentFileChangeID': 'qa-origin-alpha-homonym',
        'knownOverlappingIntervalsAreNotCausality': True,
        'inheritedPrefixSourceIDs': ['qa-child-mission', 'qa-read-beta', 'qa-child-context-diff', 'qa-origin-parent-read'],
        'inheritedPrefixRecordCount': len(inherited_prefix), 'inheritedPrefixIsNotNewExecution': True,
        'forkID': FORK, 'forkParentID': child, 'forkHistoryPrefixCopiedIntoLocalRollout': False,
        'forkHistoryBaseByteBoundary': len(prefix_bytes), 'forkContainsNoNewToolExecution': True,
        'unreceivedSendCallID': 'qa-origin-send-without-reception', 'unreceivedSendHasKnownReception': False,
        'failedPartialPatchCallID': 'qa-origin-failed-partial-patch',
        'partialEffectObservationID': 'qa-origin-partial-effect-observation', 'failedPartialPath': 'src/Partial.swift',
        'partialEffectRecordedDespiteFailure': True,
        'partialEffectAttributedToFailedPatchExplicitly': False,
        'generatorCallID': 'qa-origin-generator-call', 'generatorObservationID': 'qa-origin-generator-observation',
        'generatorDeclarationID': 'qa-origin-generator-declaration',
        'generatorAffectedPaths': ['src/GeneratedA.swift', 'src/GeneratedB.swift'],
        'generatorAndObservedFilesHaveNoExplicitSharedCallID': True,
        'manualConcurrentEditPath': str(beta / 'src/GeneratedA.swift'), 'manualEditHasRecordedAuthor': False,
        'testCallID': 'qa-origin-grand-test', 'afterSuccessfulTestChangeID': 'qa-origin-after-test-change',
        'recordedShellPatchGeneratorAndTestWereNeverExecuted': True,
        'noCauseOrJustificationFieldsInventedInSourceRecords': True,
        'baselineMissionChangedOnlyWithinNewAnonymousFixture': True,
        'versionedSourceFiles': ['protocol/src/models.rs', 'protocol/src/items.rs', 'protocol/src/protocol.rs'],
        'sourceVersion': '0.159.2'
    }
    manifest['originGeneratorSHA256'] = base.digest(Path(__file__).read_bytes())
    manifest['importedGeneratorSHA256'] = {path.name: base.digest(path.read_bytes()) for path in (
        context_path, script_dir / 'create-version-corpus-v18.py', script_dir / 'create-native-corpus-v06.py')}
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'manifest': str(manifest_path), 'rootID': root, 'childID': child,
        'grandchildID': GRANDCHILD, 'forkID': FORK, 'mainPatchID': 'qa-origin-grand-patch',
        'beforeObject': old, 'afterObject': new}, ensure_ascii=False))


if __name__ == '__main__':
    main()
