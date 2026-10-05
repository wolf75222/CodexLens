import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch, Mock


spec = importlib.util.spec_from_file_location('lens_local', Path(__file__).resolve().parents[1] / 'lens_local.py')
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


class LocalLaunchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='lens-local-test-')
        self.root = Path(self.directory.name).resolve()
        self.app = self.root / 'Lens with spaces.app'
        self.executable = self.app / 'Contents/MacOS/CodexLens'
        self.executable.parent.mkdir(parents=True)
        self.executable.write_text('anonymous fixture')
        self.executable.chmod(0o700)
        self.info = self.app / 'Contents/Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'fr.codexlens.inspector'}))
        self.record_path = self.root / 'process.json'
        self.record = {'pid': 123, 'executable': str(self.executable), 'started': 'fixture-start'}

    def tearDown(self):
        self.directory.cleanup()

    def args(self, **changes):
        values = dict(app=self.app, state_dir=self.root / 'state', action='run', restart=False,
                      no_build=True, debug=False, test_network_denied=False, app_arguments=[])
        values.update(changes)
        return argparse.Namespace(**values)

    def test_exact_matching_instance_is_reused(self):
        self.assertEqual(local.choose_instance([(123, self.executable)], self.executable), 123)

    def test_another_copy_is_refused(self):
        with self.assertRaises(local.LaunchError):
            local.choose_instance([(456, self.root / 'Other.app/Contents/MacOS/CodexLens')], self.executable)

    def test_multiple_matching_instances_are_refused(self):
        with self.assertRaises(local.LaunchError):
            local.choose_instance([(1, self.executable), (2, self.executable)], self.executable)

    def test_no_instance_allows_start(self):
        self.assertIsNone(local.choose_instance([], self.executable))

    def test_alias_of_same_bundle_is_reused(self):
        alias = self.root / 'alias.app'
        alias.symlink_to(self.app, target_is_directory=True)
        self.assertEqual(local.choose_instance([(123, self.executable)], alias / 'Contents/MacOS/CodexLens'), 123)

    def test_bundle_identity_and_paths_with_spaces(self):
        self.assertEqual(local.lens_bundle(self.executable), self.app)
        self.info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'fr.codexlens.qa.fixture'}))
        self.assertEqual(local.lens_bundle(self.executable), self.app)

    def test_invalid_bundle_metadata_is_rejected(self):
        for value in ({}, {'CFBundleIdentifier': 42}, {'CFBundleIdentifier': 'other.app'}, ['unexpected']):
            self.info.write_bytes(plistlib.dumps(value))
            self.assertIsNone(local.lens_bundle(self.executable))
        self.info.write_text('not a plist')
        self.assertIsNone(local.lens_bundle(self.executable))

    def test_record_is_atomic_and_private(self):
        local.save_record(self.record_path, self.record)
        self.assertEqual(local.load_record(self.record_path), self.record)
        self.assertEqual(self.record_path.stat().st_mode & 0o777, 0o600)
        self.assertFalse(self.record_path.with_suffix('.temporary').exists())

    def test_unreadable_record_never_becomes_stop_authorization(self):
        for value in ('not json', '[]', '{"pid":true}', '{"pid":-1,"executable":"x","started":"y"}'):
            self.record_path.write_text(value)
            with self.assertRaises(local.LaunchError):
                local.load_record(self.record_path)

    @patch.object(local, 'process_start', return_value='fixture-start')
    @patch.object(local, 'process_path')
    def test_pid_reuse_requires_both_executable_and_start_time(self, path, started):
        path.return_value = self.executable
        self.assertTrue(local.same_process(self.record))
        started.return_value = 'different-start'
        self.assertFalse(local.same_process(self.record))
        started.return_value = 'fixture-start'
        path.return_value = self.root / 'other-executable'
        self.assertFalse(local.same_process(self.record))

    @patch.object(local, 'request_native_quit')
    def test_unowned_instance_is_not_stopped(self, kill):
        self.assertFalse(local.stop_owned(self.record_path, self.executable)['stopped'])
        kill.assert_not_called()

    @patch.object(local, 'request_native_quit')
    @patch.object(local, 'same_process', return_value=False)
    def test_stale_record_is_removed_without_signal(self, same, kill):
        local.save_record(self.record_path, self.record)
        self.assertEqual(local.stop_owned(self.record_path, self.executable)['status'], 'stale-record')
        kill.assert_not_called()
        self.assertFalse(self.record_path.exists())

    @patch.object(local, 'request_native_quit')
    def test_record_for_another_path_is_refused(self, kill):
        local.save_record(self.record_path, self.record)
        with self.assertRaises(local.LaunchError):
            local.stop_owned(self.record_path, self.root / 'Other')
        kill.assert_not_called()

    @patch.object(local, 'request_native_quit')
    @patch.object(local, 'same_process', side_effect=[True, False])
    def test_identity_change_before_signal_is_refused(self, same, kill):
        local.save_record(self.record_path, self.record)
        with self.assertRaises(local.LaunchError):
            local.stop_owned(self.record_path, self.executable)
        kill.assert_not_called()

    @patch.object(local, 'request_native_quit')
    @patch.object(local, 'same_process', side_effect=[True, True, False, False])
    def test_owned_process_is_stopped_without_force(self, same, kill):
        local.save_record(self.record_path, self.record)
        self.assertTrue(local.stop_owned(self.record_path, self.executable)['stopped'])
        kill.assert_called_once_with(self.record)
        self.assertFalse(self.record_path.exists())

    @patch.object(local, 'request_native_quit')
    @patch.object(local, 'same_process', return_value=True)
    def test_stop_timeout_keeps_record_and_does_not_force(self, same, kill):
        local.save_record(self.record_path, self.record)
        with self.assertRaises(local.LaunchError):
            local.stop_owned(self.record_path, self.executable, timeout=0)
        self.assertTrue(self.record_path.exists())
        kill.assert_called_once_with(self.record)

    @patch.object(local.subprocess, 'Popen')
    @patch.object(local.subprocess, 'run')
    @patch.object(local, 'running_lens')
    def test_default_reuse_does_not_build_or_launch(self, running, run, popen):
        running.return_value = [(123, self.executable)]
        self.assertEqual(local.run(self.args(no_build=False))['status'], 'already-running')
        run.assert_not_called()
        popen.assert_not_called()

    @patch.object(local.subprocess, 'Popen')
    @patch.object(local, 'running_lens')
    def test_restart_does_not_claim_external_instance(self, running, popen):
        running.return_value = [(123, self.executable)]
        with self.assertRaises(local.LaunchError):
            local.run(self.args(restart=True))
        popen.assert_not_called()

    @patch.object(local.subprocess, 'Popen')
    @patch.object(local.subprocess, 'run')
    @patch.object(local, 'running_lens', side_effect=[[], []])
    def test_early_process_exit_is_not_success(self, running, run, popen):
        child = Mock()
        child.poll.return_value = 0
        popen.return_value = child
        with self.assertRaises(local.LaunchError):
            local.run(self.args())
        self.assertFalse((self.root / 'state/process.json').exists())

    @patch.object(local.subprocess, 'Popen')
    @patch.object(local.subprocess, 'run')
    @patch.object(local, 'running_lens', return_value=[])
    def test_build_failure_never_launches(self, running, run, popen):
        run.side_effect = subprocess.CalledProcessError(1, ['fixture-build'])
        with self.assertRaises(subprocess.CalledProcessError):
            local.run(self.args(no_build=False))
        popen.assert_not_called()
        self.assertEqual(run.call_args.args[0], [str(local.ROOT / 'scripts/build.sh')])
        self.assertEqual(run.call_args.kwargs['env']['LENS_APP_PATH'], str(self.app))

    @patch.object(local.subprocess, 'run')
    def test_native_quit_helper_preserves_identity_as_literal_arguments(self, run):
        local.request_native_quit(self.record)
        self.assertEqual(run.call_args.args[0][-3:], ['123', str(self.executable), 'fixture-start'])
        self.assertTrue(run.call_args.kwargs['check'])

    @patch.object(local, 'request_native_quit', side_effect=local.LaunchError('fixture refusal'))
    @patch.object(local, 'same_process', return_value=True)
    def test_native_quit_refusal_keeps_ownership_record(self, same, quit):
        local.save_record(self.record_path, self.record)
        with self.assertRaises(local.LaunchError):
            local.stop_owned(self.record_path, self.executable)
        self.assertTrue(self.record_path.exists())

    @patch.object(local.subprocess, 'Popen')
    @patch.object(local.subprocess, 'run')
    @patch.object(local, 'running_lens')
    def test_instance_started_during_build_is_reused(self, running, run, popen):
        running.side_effect = [[], [(123, self.executable)]]
        self.assertEqual(local.run(self.args(no_build=False))['status'], 'already-running')
        popen.assert_not_called()

    @patch.object(local, 'process_start', return_value='fixture-start')
    @patch.object(local, 'process_path')
    @patch.object(local.subprocess, 'Popen')
    @patch.object(local.subprocess, 'run')
    @patch.object(local, 'running_lens', return_value=[])
    def test_successful_qa_launch_preserves_literal_arguments_and_records_identity(self, running, run, popen, path, started):
        path.return_value = self.executable
        child = Mock(pid=123)
        child.wait.side_effect = subprocess.TimeoutExpired('fixture', 1)
        child.poll.return_value = None
        popen.return_value = child
        result = local.run(self.args(test_network_denied=True, app_arguments=['--session', 'fixture-id with spaces']))
        self.assertEqual(result['status'], 'started')
        command = popen.call_args.args[0]
        self.assertEqual(command[-3:], [str(self.executable), '--session', 'fixture-id with spaces'])
        self.assertEqual(command[0], '/usr/bin/sandbox-exec')
        self.assertTrue(local.load_record(self.root / 'state/process.json')['networkDeniedForTest'])

    @patch.object(local.subprocess, 'Popen')
    @patch.object(local, 'stop_owned')
    @patch.object(local, 'same_process', return_value=True)
    @patch.object(local, 'running_lens')
    def test_failed_owned_stop_never_launches_replacement(self, running, same, stop, popen):
        state = self.root / 'state'
        state.mkdir()
        local.save_record(state / 'process.json', self.record)
        running.return_value = [(123, self.executable)]
        stop.side_effect = local.LaunchError('fixture timeout')
        with self.assertRaises(local.LaunchError):
            local.run(self.args(restart=True))
        popen.assert_not_called()


if __name__ == '__main__':
    unittest.main()
