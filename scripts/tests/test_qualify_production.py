"""Regression checks for the QA launcher; never launch a GUI application."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "qualify-production-v06.py"
spec = importlib.util.spec_from_file_location("qualify_production", SCRIPT)
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)


class QALaunchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def app(self, name, identifier=None):
        app = self.root / name
        if identifier:
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(
                plistlib.dumps({"CFBundleIdentifier": identifier}))
        return app / "Contents/MacOS/CodexLens"

    def test_production_windows_are_excluded(self):
        executable = self.app("Codex Lens.app", "fr.codexlens.app")
        self.assertEqual(qa.running_qa_apps("12 %s\n13 %s" % (executable, executable)), [])

    def test_qa_identifier_is_detected_even_with_old_bundle_name(self):
        executable = self.app("Codex Lens.app", "fr.codexlens.qa.v06.example")
        self.assertEqual(qa.running_qa_apps("22 " + str(executable))[0]["pid"], 22)

    def test_live_deleted_test_bundle_is_detected(self):
        for name in ("Codex Lens QA.app", "Codex Lens (test).app"):
            executable = self.app(name)
            self.assertEqual(qa.running_qa_apps("23 " + str(executable))[0]["pid"], 23)

    def test_unrelated_processes_and_arguments_are_not_apps(self):
        executable = self.app("Codex Lens (test).app")
        self.assertEqual(qa.running_qa_apps("header\n24 /usr/bin/python3\n25 %s --session test" % executable), [])

    def test_existing_test_copy_blocks_new_launch_without_killing_it(self):
        active = [{"pid": 99, "app": str(self.root / "Codex Lens QA.app")}]
        with patch.object(qa, "running_qa_apps", return_value=active), patch.object(qa.os, "kill") as kill:
            with self.assertRaisesRegex(SystemExit, "already open"):
                with qa.exclusive_qa_launch(self.root / "launch.lock"):
                    self.fail("Must not reach launch")
            kill.assert_not_called()

    def test_simultaneous_launcher_is_blocked_and_lock_releases(self):
        lock = self.root / "launch.lock"
        with patch.object(qa, "running_qa_apps", return_value=[]):
            with qa.exclusive_qa_launch(lock):
                with self.assertRaisesRegex(SystemExit, "in progress"):
                    with qa.exclusive_qa_launch(lock):
                        self.fail("Second launch must be blocked")
            with qa.exclusive_qa_launch(lock):
                pass

    def test_process_inspection_failure_blocks_launch(self):
        with patch.object(qa, "command", return_value={"status": 1, "stdout": ""}):
            with self.assertRaisesRegex(SystemExit, "Cannot inspect"):
                qa.running_qa_apps()

    def test_lock_symlink_is_rejected(self):
        target = self.root / "untouched"
        target.write_text("unchanged")
        link = self.root / "launch.lock"
        link.symlink_to(target)
        with self.assertRaises(OSError):
            with qa.exclusive_qa_launch(link):
                self.fail("Must reject symlink")
        self.assertEqual(target.read_text(), "unchanged")


if __name__ == "__main__":
    unittest.main()
