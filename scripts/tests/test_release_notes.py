"""Exercise release preparation against anonymous, local Git repositories."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("release_notes_under_test", ROOT / "scripts/release_notes.py")
release_notes = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release_notes)


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="lens-release-notes-")
        self.addCleanup(self.scratch.cleanup)
        self.base = Path(self.scratch.name).resolve()
        self.root = self.base / "repository"
        self.root.mkdir()
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        environment.update({
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Anonymous Release Test",
            "GIT_AUTHOR_EMAIL": "release-test@example.invalid",
            "GIT_COMMITTER_NAME": "Anonymous Release Test",
            "GIT_COMMITTER_EMAIL": "release-test@example.invalid",
        })
        self.environment = mock.patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.info = {"CFBundleIdentifier": "fr.codexlens.inspector",
                     "CFBundleShortVersionString": "0.41.0", "CFBundleVersion": "75"}
        (self.root / "Support").mkdir()
        (self.root / "docs/releases").mkdir(parents=True)
        self.save_info()
        self.save_changelog()
        (self.root / "docs/releases/0.41.0.md").write_text(
            "# Codex Lens 0.41.0\n\nInitial public fixture release.\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("config", "commit.gpgsign", "false")
        self.git("config", "core.hooksPath", str(self.base / "no-hooks"))
        self.commit()

    def git(self, *arguments, check=True):
        return subprocess.run(["git", *arguments], cwd=self.root, text=True,
                              capture_output=True, check=check)

    def commit(self):
        self.git("add", "--all")
        self.git("commit", "--quiet", "--no-verify", "-m", "Anonymous fixture")

    def save_info(self):
        (self.root / "Support/Info.plist").write_bytes(plistlib.dumps(self.info))

    def changelog(self, versions=("0.41.0",), days=None,
                  unreleased="### Fixed\n\n- Preserve selection after changing sessions.\n"):
        days = days or ["2026-10-05"] * len(versions)
        text = "# Changelog\n\n## [Unreleased]\n\n" + unreleased.strip() + "\n\n"
        for version, day in zip(versions, days):
            text += f"## [{version}] - {day}\n\n### Added\n\n- Anonymous fixture change.\n\n"
        links = release_notes.comparison_links(list(versions))
        return text + "".join(f"[{key}]: {value}\n" for key, value in links.items())

    def save_changelog(self, **parameters):
        (self.root / "CHANGELOG.md").write_text(self.changelog(**parameters), encoding="utf-8")

    def files(self):
        result = {}
        for path in self.root.rglob("*"):
            relative = path.relative_to(self.root)
            if ".git" in relative.parts:
                continue
            if path.is_symlink():
                result[str(relative)] = ("symlink", os.readlink(path))
            elif path.is_file():
                result[str(relative)] = path.read_bytes()
        return result

    def invoke(self, *arguments):
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(release_notes, "ROOT", self.root), \
                mock.patch("sys.argv", ["release_notes.py", *arguments]), \
                contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
            try:
                release_notes.main()
                status = 0
            except SystemExit as error:
                status = error.code
        return status, output.getvalue(), errors.getvalue()

    def plan(self, version="0.41.1", day="2026-10-06", build=None):
        return release_notes.plan_release(self.root, version, day, build)

    def assert_rejected_without_writes(self, operation):
        before = self.files()
        with self.assertRaises((ValueError, KeyError, OSError)):
            operation()
        self.assertEqual(self.files(), before)

    def test_prepare_defaults_to_preview_without_changing_files_index_head_or_tags(self):
        before = self.files()
        head = self.git("rev-parse", "HEAD").stdout
        status, output, errors = self.invoke("prepare", "0.41.1", "--date", "2026-10-06")
        self.assertEqual(status, 0, errors)
        self.assertIn("Preview only", output)
        self.assertIn("diff --git a/Support/Info.plist", output)
        self.assertIn("new file mode 100644", output)
        self.assertEqual(self.files(), before)
        self.assertEqual(self.git("status", "--porcelain").stdout, "")
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, head)
        self.assertEqual(self.git("tag", "--list").stdout, "")

    def test_preview_patch_applies_with_git_and_preserves_release_consistency(self):
        before = self.files()
        head = self.git("rev-parse", "HEAD").stdout
        plan = self.plan()
        patch = release_notes.patch_for_plan(plan)
        self.assertEqual(self.files(), before)
        subprocess.run(["git", "apply", "--check", "--whitespace=error", "-"],
                       cwd=self.root, input=patch, text=True, capture_output=True, check=True)
        release_notes.write_plan(self.root, plan)
        info, changelog = release_notes.validate_repository(self.root, tag="v0.41.1")
        self.assertEqual(info["CFBundleShortVersionString"], "0.41.1")
        self.assertEqual(info["CFBundleVersion"], "76")
        self.assertEqual(changelog["versions"], ["0.41.1", "0.41.0"])
        self.assertEqual(changelog["unreleased"], "")
        self.assertIn("Preserve selection", (self.root / "docs/releases/0.41.1.md").read_text())
        self.assertEqual(self.git("diff", "--cached", "--name-only").stdout, "")
        self.assertEqual(self.git("rev-parse", "HEAD").stdout, head)
        self.assertEqual(self.git("tag", "--list").stdout, "")

    def test_two_sequential_writes_keep_versions_builds_history_and_links_consistent(self):
        original_notes = (self.root / "docs/releases/0.41.0.md").read_bytes()
        status, _, errors = self.invoke("prepare", "0.41.1", "--date", "2026-10-06", "--write")
        self.assertEqual(status, 0, errors)
        first_notes = (self.root / "docs/releases/0.41.1.md").read_bytes()
        log = self.root / "CHANGELOG.md"
        log.write_text(log.read_text().replace("## [Unreleased]\n\n", "## [Unreleased]\n\n### Changed\n\n- Improve keyboard navigation.\n\n", 1))
        self.commit()
        status, _, errors = self.invoke("prepare", "0.41.2", "--date", "2026-10-07", "--build", "80", "--write")
        self.assertEqual(status, 0, errors)
        info, changelog = release_notes.validate_repository(self.root, tag="v0.41.2")
        self.assertEqual(info["CFBundleVersion"], "80")
        self.assertEqual(changelog["versions"], ["0.41.2", "0.41.1", "0.41.0"])
        self.assertEqual(changelog["unreleased"], "")
        self.assertEqual((self.root / "docs/releases/0.41.0.md").read_bytes(), original_notes)
        self.assertEqual((self.root / "docs/releases/0.41.1.md").read_bytes(), first_notes)
        newest = (self.root / "docs/releases/0.41.2.md").read_text()
        self.assertIn("Improve keyboard navigation", newest)
        self.assertNotIn("Preserve selection", newest)
        self.assertIn("/compare/v0.41.1...v0.41.2", log.read_text())
        self.assertEqual(self.git("tag", "--list").stdout, "")

    def test_stale_plist_or_changelog_plan_is_rejected_without_partial_writes(self):
        for name in ("Support/Info.plist", "CHANGELOG.md"):
            with self.subTest(name=name):
                plan = self.plan()
                target = self.root / name
                original = target.read_bytes()
                target.write_bytes(original + b"\n")
                self.assert_rejected_without_writes(lambda: release_notes.write_plan(self.root, plan))
                target.write_bytes(original)

    def test_notes_appearing_after_preview_are_not_overwritten(self):
        plan = self.plan()
        target = self.root / "docs/releases/0.41.1.md"
        target.write_text("Existing independently prepared notes.\n")
        self.assert_rejected_without_writes(lambda: release_notes.write_plan(self.root, plan))

    def test_notes_collision_during_planning_is_rejected_without_writes(self):
        (self.root / "docs/releases/0.41.1.md").write_text("Existing notes.\n")
        self.assert_rejected_without_writes(self.plan)

    def test_complete_patch_failure_does_not_partially_update_existing_files(self):
        plan = self.plan()
        release_directory = self.root / "docs/releases"
        renamed = self.root / "docs/previous-releases"
        release_directory.rename(renamed)
        release_directory.write_text("A file cannot be used as the releases directory.\n")
        self.assert_rejected_without_writes(lambda: release_notes.write_plan(self.root, plan))

    def test_partial_apply_io_failure_rolls_back_only_its_exact_outputs(self):
        plan = self.plan()
        real_run = subprocess.run

        def fail_after_partial_write(command, **parameters):
            if command[:2] == ["git", "apply"] and "--check" not in command:
                for name in ("Support/Info.plist", "docs/releases/0.41.1.md"):
                    (self.root / name).write_text(plan[name][1], encoding="utf-8")
                return subprocess.CompletedProcess(command, 1, "", "Synthetic apply I/O failure")
            return real_run(command, **parameters)

        with mock.patch.object(subprocess, "run", side_effect=fail_after_partial_write) as calls:
            self.assert_rejected_without_writes(lambda: release_notes.write_plan(self.root, plan))
        self.assertEqual(calls.call_count, 2, "The complete patch is checked by real Git before the injected failure")
        self.assertEqual(self.git("status", "--porcelain").stdout, "")

    def test_partial_apply_rollback_preserves_and_reports_an_outside_edit(self):
        plan = self.plan()
        real_run = subprocess.run
        original_info = (self.root / "Support/Info.plist").read_bytes()
        outside_edit = plan["CHANGELOG.md"][0] + "\nAn independently edited note.\n"

        def fail_after_outside_edit(command, **parameters):
            if command[:2] == ["git", "apply"] and "--check" not in command:
                for name in ("Support/Info.plist", "docs/releases/0.41.1.md"):
                    (self.root / name).write_text(plan[name][1], encoding="utf-8")
                (self.root / "CHANGELOG.md").write_text(outside_edit, encoding="utf-8")
                return subprocess.CompletedProcess(command, 1, "", "Synthetic apply I/O failure")
            return real_run(command, **parameters)

        with mock.patch.object(subprocess, "run", side_effect=fail_after_outside_edit):
            with self.assertRaisesRegex(ValueError, "Recovery needs manual inspection: CHANGELOG.md"):
                release_notes.write_plan(self.root, plan)
        self.assertEqual((self.root / "Support/Info.plist").read_bytes(), original_info)
        self.assertEqual((self.root / "CHANGELOG.md").read_text(), outside_edit)
        self.assertFalse((self.root / "docs/releases/0.41.1.md").exists())
        self.assertEqual(self.git("diff", "--cached", "--name-only").stdout, "")

    def test_invalid_new_versions_dates_and_builds_do_not_change_metadata(self):
        cases = [(value, "2026-10-06", None) for value in
                 ("v0.41.1", "0.41", "0.041.1", "0.41.01", "0.41.1-beta", "../other", "0.41.0", "0.40.9",
                  "0.4\u0661.1", "0.41.1\uff12")]
        cases += [("0.41.1", value, None) for value in
                  ("2026-02-29", "2026-13-01", "20261006", "2026-10-6", "2026-10-04")]
        cases += [("0.41.1", "2026-10-06", value) for value in
                  ("0", "75", "74", "076", "-1", "76.0", "", "not-a-build", "7\u0666")]
        for version, day, build in cases:
            with self.subTest(version=version, day=day, build=build):
                self.assert_rejected_without_writes(lambda: self.plan(version, day, build))

    def test_invalid_existing_build_or_qa_environment_is_rejected(self):
        for value in ("0", "01", "-1", "1.0", "", False, 75, "7\u0665"):
            with self.subTest(build=value):
                self.info["CFBundleVersion"] = value
                self.save_info()
                self.assert_rejected_without_writes(lambda: release_notes.validate_repository(self.root))
        self.info["CFBundleVersion"] = "75"
        self.info["LSEnvironment"] = {}
        self.save_info()
        self.assert_rejected_without_writes(lambda: release_notes.validate_repository(self.root))

    def test_duplicate_or_ascending_releases_and_increasing_historical_dates_are_rejected(self):
        cases = [(("0.41.0", "0.41.0"), None),
                 (("0.41.0", "0.42.0"), None),
                 (("0.41.0", "0.40.0"), ("2026-10-05", "2026-10-06"))]
        for versions, days in cases:
            with self.subTest(versions=versions, days=days):
                text = self.changelog(versions=versions, days=days)
                with self.assertRaises(ValueError):
                    release_notes.parse_changelog(text)

    def test_duplicate_invalid_or_empty_categories_are_rejected(self):
        for body in ("### Fixed\n\n- First.\n\n### Fixed\n\n- Second.\n",
                     "### Miscellaneous\n\n- Change.\n", "### Fixed\n\nNo bullet.\n"):
            with self.subTest(body=body):
                with self.assertRaises(ValueError):
                    release_notes.parse_changelog(self.changelog(unreleased=body))

    def test_mismatched_app_changelog_notes_and_tag_are_rejected(self):
        self.assert_rejected_without_writes(lambda: release_notes.validate_repository(self.root, tag="v0.41.1"))
        self.info["CFBundleShortVersionString"] = "0.40.9"
        self.save_info()
        self.assert_rejected_without_writes(lambda: release_notes.validate_repository(self.root))
        self.info["CFBundleShortVersionString"] = "0.41.0"
        self.save_info()
        notes = self.root / "docs/releases/0.41.0.md"
        for text in ("# Codex Lens 0.40.9\n\nWrong version.\n", "# Codex Lens 0.41.0\n\n"):
            with self.subTest(notes=text):
                notes.write_text(text)
                self.assert_rejected_without_writes(lambda: release_notes.validate_repository(self.root))

    def test_missing_or_duplicate_or_incorrect_comparison_links_are_rejected(self):
        text = self.changelog()
        first_link = "[Unreleased]: " + release_notes.comparison_links(["0.41.0"])["Unreleased"] + "\n"
        for broken in (text.replace(first_link, ""), text + first_link,
                       text.replace("compare/v0.41.0...main", "compare/v0.40.0...main")):
            with self.subTest(changelog=broken):
                with self.assertRaises(ValueError):
                    release_notes.parse_changelog(broken)

    def test_empty_unreleased_is_valid_for_check_but_refused_for_prepare(self):
        self.save_changelog(unreleased="")
        release_notes.validate_repository(self.root, tag="v0.41.0")
        self.assert_rejected_without_writes(self.plan)

    def test_write_requires_clean_checkout_but_preview_remains_available(self):
        for dirty in ("tracked", "untracked"):
            with self.subTest(dirty=dirty):
                target = self.root / ("CHANGELOG.md" if dirty == "tracked" else "untracked.txt")
                original = target.read_bytes() if target.exists() else None
                target.write_bytes((original or b"") + b"\nPending local change.\n")
                before = self.files()
                status, _, errors = self.invoke("prepare", "0.41.1", "--date", "2026-10-06", "--write")
                self.assertEqual(status, 1)
                self.assertIn("Commit or stash", errors)
                self.assertEqual(self.files(), before)
                status, output, errors = self.invoke("prepare", "0.41.1", "--date", "2026-10-06")
                self.assertEqual(status, 0, errors)
                self.assertIn("Preview only", output)
                self.assertEqual(self.files(), before)
                if original is None:
                    target.unlink()
                else:
                    target.write_bytes(original)

    def test_existing_local_release_tag_is_protected_without_modifying_files_or_tag(self):
        self.git("tag", "v0.41.1")
        before = self.files()
        tag = self.git("rev-parse", "refs/tags/v0.41.1").stdout
        status, _, errors = self.invoke("prepare", "0.41.1", "--date", "2026-10-06", "--write")
        self.assertEqual(status, 1)
        self.assertIn("local release tag already exists", errors)
        self.assertEqual(self.files(), before)
        self.assertEqual(self.git("rev-parse", "refs/tags/v0.41.1").stdout, tag)

    def test_valid_check_and_invalid_cli_arguments_have_no_side_effects(self):
        before = self.files()
        status, output, errors = self.invoke("check", "--tag", "v0.41.0")
        self.assertEqual(status, 0, errors)
        self.assertIn("0.41.0 (build 75)", output)
        for arguments in (("check", "--tag", "v0.41.1"),
                          ("prepare", "0.41.1", "--date", "invalid"),
                          ("prepare", "0.41.1", "--build", "invalid")):
            with self.subTest(arguments=arguments):
                status, _, errors = self.invoke(*arguments)
                self.assertEqual(status, 1)
                self.assertIn("Release preparation failed", errors)
                self.assertEqual(self.files(), before)

    def test_symlinked_source_files_are_rejected_without_reading_targets(self):
        for name in ("Support/Info.plist", "CHANGELOG.md", "docs/releases/0.41.0.md"):
            with self.subTest(name=name):
                target = self.root / name
                original = target.read_bytes()
                outside = self.base / "outside-source"
                outside.write_bytes(b"Anonymous target; must not be parsed or changed.\n")
                target.unlink()
                target.symlink_to(outside)
                with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("Linked bytes must not be read")):
                    with self.assertRaisesRegex(ValueError, "symbolic links"):
                        release_notes.regular_file(self.root, name)
                self.assert_rejected_without_writes(lambda: release_notes.validate_repository(self.root))
                self.assertEqual(outside.read_bytes(), b"Anonymous target; must not be parsed or changed.\n")
                target.unlink()
                target.write_bytes(original)

    def test_symlinked_source_directory_is_rejected(self):
        support = self.root / "Support"
        moved = self.base / "external-support"
        support.rename(moved)
        support.symlink_to(moved, target_is_directory=True)
        with mock.patch.object(Path, "read_bytes", side_effect=AssertionError("Linked directories must not be read")):
            with self.assertRaisesRegex(ValueError, "symbolic links"):
                release_notes.regular_file(self.root, "Support/Info.plist")
        self.assert_rejected_without_writes(lambda: release_notes.validate_repository(self.root))

    def test_broken_symlink_for_future_notes_is_not_overwritten(self):
        future = self.root / "docs/releases/0.41.1.md"
        outside = self.base / "nonexistent-target"
        future.symlink_to(outside)
        self.assert_rejected_without_writes(self.plan)
        self.assertFalse(outside.exists())

    def test_symlinked_notes_directory_after_preview_cannot_escape_checkout(self):
        plan = self.plan()
        directory = self.root / "docs/releases"
        directory.rename(self.root / "docs/old-releases")
        outside = self.base / "external-releases"
        outside.mkdir()
        directory.symlink_to(outside, target_is_directory=True)
        self.assert_rejected_without_writes(lambda: release_notes.write_plan(self.root, plan))
        self.assertEqual(list(outside.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
