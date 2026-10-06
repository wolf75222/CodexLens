import importlib.util
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sparkle_bundle", ROOT / "scripts/sparkle_bundle.py")
sparkle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sparkle)


class SparkleBundleTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.xcframework = self.root / "artifact/Sparkle.xcframework"
        self.framework = self.xcframework / "macos-arm64_x86_64/Sparkle.framework"
        self.save_xcframework()
        versioned = self.framework / "Versions/B"
        (versioned / "Resources").mkdir(parents=True)
        self.save_info(versioned / "Resources/Info.plist", "Sparkle", identifier="org.sparkle-project.Sparkle")
        for name in ["Sparkle", "Autoupdate"]:
            self.executable(versioned / name)
        for relative, name in sparkle.NESTED_BUNDLES.items():
            bundle = self.framework / relative
            self.save_info(bundle / "Contents/Info.plist", name)
            self.executable(bundle / "Contents/MacOS" / name)
        for relative, target in sparkle.FRAMEWORK_LINKS.items():
            (self.framework / relative).symlink_to(target)

    def save_xcframework(self, **overrides):
        self.xcframework.mkdir(parents=True, exist_ok=True)
        library = {"SupportedPlatform": "macos", "SupportedArchitectures": ["arm64", "x86_64"],
                   "LibraryIdentifier": "macos-arm64_x86_64", "LibraryPath": "Sparkle.framework"}
        library.update(overrides)
        (self.xcframework / "Info.plist").write_bytes(plistlib.dumps({"AvailableLibraries": [library]}))

    def save_info(self, path, executable, *, minimum="12.0", identifier="fixture"):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(plistlib.dumps({"CFBundleExecutable": executable, "CFBundleIdentifier": identifier,
                                       "CFBundleShortVersionString": "2.10.0", "LSMinimumSystemVersion": minimum}))

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"fixture, never launched")
        path.chmod(0o755)

    def test_selects_macos_arm64_artifact_and_compatible_helpers(self):
        self.assertEqual(sparkle.find_framework(self.root, "arm64", "14.0"), self.framework)
        self.assertEqual(len(sparkle.framework_structure(self.framework, "14.0")), 5)

    def test_rejects_an_ios_artifact_with_the_same_architecture(self):
        self.save_xcframework(SupportedPlatform="ios")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            sparkle.find_framework(self.root, "arm64", "14.0")

    def test_rejects_duplicate_compatible_artifacts(self):
        info = plistlib.loads((self.xcframework / "Info.plist").read_bytes())
        info["AvailableLibraries"].append(dict(info["AvailableLibraries"][0]))
        (self.xcframework / "Info.plist").write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(ValueError, "exactly one"):
            sparkle.find_framework(self.root, "arm64", "14.0")

    def test_rejects_path_traversal_in_artifact_manifest(self):
        self.save_xcframework(LibraryIdentifier="../../outside")
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            sparkle.find_framework(self.root, "arm64", "14.0")

    def test_rejects_framework_directory_links(self):
        link = self.root / "Linked.framework"
        link.symlink_to(self.framework)
        with self.assertRaisesRegex(ValueError, "directory"):
            sparkle.framework_structure(link, "14.0")

    def test_rejects_a_flattened_versioned_framework(self):
        link = self.framework / "Sparkle"
        link.unlink()
        self.executable(link)
        with self.assertRaisesRegex(ValueError, "symlink layout"):
            sparkle.framework_structure(self.framework, "14.0")

    def test_rejects_external_and_broken_links(self):
        link = self.framework / "External"
        for target in [self.root, self.root / "does-not-exist"]:
            link.symlink_to(target)
            with self.assertRaisesRegex(ValueError, "external or broken"):
                sparkle.framework_structure(self.framework, "14.0")
            link.unlink()

    def test_rejects_newer_helper_minimum_os(self):
        self.save_info(self.framework / "Versions/B/Updater.app/Contents/Info.plist", "Updater", minimum="15.0")
        with self.assertRaisesRegex(ValueError, "newer macOS"):
            sparkle.framework_structure(self.framework, "14.0")

    def test_rejects_missing_executable_permissions(self):
        (self.framework / "Versions/B/Autoupdate").chmod(0o644)
        with self.assertRaisesRegex(ValueError, "not executable"):
            sparkle.framework_structure(self.framework, "14.0")

    def test_signature_plan_is_inside_out_and_never_deep_signs(self):
        commands = sparkle.signing_commands(self.root / "Fixture.app", "-")
        suffixes = ["Installer.xpc", "Downloader.xpc", "Autoupdate", "Updater.app", "Sparkle.framework", "Fixture.app"]
        self.assertEqual([Path(command[-1]).name for command in commands[:-1]], suffixes)
        self.assertTrue(all("--deep" not in command for command in commands[:-1]))
        self.assertEqual(commands[-1][1:5], ["--verify", "--deep", "--strict", str(self.root / "Fixture.app")])
        preserve = [command for command in commands if "--preserve-metadata=entitlements" in command]
        self.assertEqual(len(preserve), 1)
        self.assertTrue(preserve[0][-1].endswith("Downloader.xpc"))
        self.assertTrue(all("--timestamp" not in command for command in commands))

    def test_developer_identity_enables_runtime_and_timestamp_everywhere(self):
        commands = sparkle.signing_commands(self.root / "Fixture.app", "Developer ID Application: Fixture")
        self.assertTrue(all("--timestamp" in command and "runtime" in command for command in commands[:-1]))

    def linkage(self, dependencies=None, rpath="@executable_path/../Frameworks", minimum="14.0"):
        dependencies = dependencies or [sparkle.FRAMEWORK_LOAD_PATH, "/usr/lib/libSystem.B.dylib"]
        return ["Fixture:\n" + "\n".join("\t" + path + " (compatibility version 1.0.0)" for path in dependencies),
                "Load command 10\n cmd LC_RPATH\n cmdsize 48\n path " + rpath + " (offset 12)",
                " platform MACOS\n minos " + minimum + "\n sdk 26.5"]

    def test_application_requires_embedded_framework_and_runtime_search_path(self):
        with patch.object(sparkle, "run", side_effect=self.linkage()):
            sparkle.validate_linkage(self.root / "Fixture", "14.0", application=True)
        for output in [self.linkage(dependencies=["/usr/lib/libSystem.B.dylib"]), self.linkage(rpath="@loader_path")]:
            with patch.object(sparkle, "run", side_effect=output), self.assertRaisesRegex(ValueError, "embedded"):
                sparkle.validate_linkage(self.root / "Fixture", "14.0", application=True)

    def test_external_build_library_or_search_path_is_rejected(self):
        for output in [self.linkage(dependencies=["/build/Sparkle.framework/Sparkle"]), self.linkage(rpath="/private/build/artifacts")]:
            with patch.object(sparkle, "run", side_effect=output), self.assertRaisesRegex(ValueError, "outside|external"):
                sparkle.validate_linkage(self.root / "Fixture", "14.0", application=True)

    def test_binary_minimum_os_is_validated_for_each_architecture(self):
        with patch.object(sparkle, "run", side_effect=self.linkage(minimum="15.0")), self.assertRaisesRegex(ValueError, "deployment"):
            sparkle.validate_linkage(self.root / "Fixture", "14.0", application=True)

    def test_catalyst_minimum_does_not_replace_the_macos_minimum(self):
        output = self.linkage()
        output[-1] += "\n platform MACCATALYST\n minos 26.0\n sdk 26.5"
        with patch.object(sparkle, "run", side_effect=output):
            sparkle.validate_linkage(self.root / "Fixture", "14.0", application=True)

    def runtime_fixture(self):
        app = self.root / "RuntimeFixture.app"
        self.save_info(app / "Contents/Info.plist", "Fixture", minimum="14.0")
        self.executable(app / "Contents/MacOS/Fixture")
        (app / "Contents/Frameworks").mkdir()
        tool = self.root / "Active.xctoolchain/usr/bin/swift-stdlib-tool"
        tool.parent.mkdir(parents=True)
        tool.write_text("fixture")
        library_directory = tool.parent.parent / "lib/swift-6.2/macosx"
        library_directory.mkdir(parents=True)
        return app, tool, library_directory

    def test_only_existing_active_toolchain_swift_macos_paths_are_removable(self):
        _, tool, library_directory = self.runtime_fixture()
        self.assertTrue(sparkle.toolchain_swift_path(str(library_directory), tool))
        for path in [self.root, tool.parent, library_directory / "missing", "/usr/lib/swift"]:
            self.assertFalse(sparkle.toolchain_swift_path(str(path), tool))
        unrelated = self.root / "Other.xctoolchain/usr/lib/swift-6.2/macosx"
        unrelated.mkdir(parents=True)
        self.assertFalse(sparkle.toolchain_swift_path(str(unrelated), tool))

    def runtime_runner(self, app, tool, library_directory, *, copy=True, failure=False):
        commands = []

        def execute(command):
            commands.append(command)
            if command[:2] == ["xcrun", "--find"]:
                return str(tool)
            if command[:2] == ["otool", "-l"]:
                return self.linkage(rpath=str(library_directory))[1]
            if command[:2] == ["xcrun", "swift-stdlib-tool"]:
                if failure:
                    raise RuntimeError("scanner failed")
                if copy and "--source-libraries" in command:
                    self.executable(app / "Contents/Frameworks/libswiftCompatibilitySpan.dylib")
                return ""
            if command[:2] == ["otool", "-L"]:
                return self.linkage(dependencies=["@rpath/libswiftCompatibilitySpan.dylib"])[0]
            return ""

        return execute, commands

    def test_runtime_copy_precedes_toolchain_rpath_removal(self):
        app, tool, library_directory = self.runtime_fixture()
        execute, commands = self.runtime_runner(app, tool, library_directory)
        with patch.object(sparkle, "run", side_effect=execute), patch.object(sparkle, "framework_structure", return_value=[]):
            sparkle.prepare_runtime(app)
        copying = [index for index, command in enumerate(commands) if "swift-stdlib-tool" in command]
        deletion = [index for index, command in enumerate(commands) if command[0] == "install_name_tool"]
        self.assertTrue(copying and deletion and max(copying) < min(deletion))
        self.assertEqual(commands[deletion[0]][1:3], ["-delete_rpath", str(library_directory)])

    def test_missing_required_runtime_library_preserves_toolchain_paths(self):
        app, tool, library_directory = self.runtime_fixture()
        execute, commands = self.runtime_runner(app, tool, library_directory, copy=False)
        with patch.object(sparkle, "run", side_effect=execute), patch.object(sparkle, "framework_structure", return_value=[]):
            with self.assertRaisesRegex(ValueError, "not embedded"):
                sparkle.prepare_runtime(app)
        self.assertFalse(any(command[0] == "install_name_tool" for command in commands))

    def test_scanner_failure_never_removes_toolchain_paths(self):
        app, tool, library_directory = self.runtime_fixture()
        execute, commands = self.runtime_runner(app, tool, library_directory, failure=True)
        with patch.object(sparkle, "run", side_effect=execute), patch.object(sparkle, "framework_structure", return_value=[]):
            with self.assertRaisesRegex(RuntimeError, "scanner failed"):
                sparkle.prepare_runtime(app)
        self.assertFalse(any(command[0] == "install_name_tool" for command in commands))

    def test_swift_runtime_is_signed_before_enclosing_frameworks_and_app(self):
        app, _, _ = self.runtime_fixture()
        library = app / "Contents/Frameworks/libswiftCompatibilitySpan.dylib"
        self.executable(library)
        commands = sparkle.signing_commands(app, "-")
        self.assertEqual(commands[0][-1], str(library))
        self.assertEqual(commands[-2][-1], str(app))

    def test_required_absolute_swift_compatibility_name_is_copied_explicitly(self):
        app, tool, library_directory = self.runtime_fixture()
        library_name = "libswiftCompatibilitySpan.dylib"
        self.executable(library_directory / library_name)
        commands = []

        def execute(command):
            commands.append(command)
            if command[:2] == ["xcrun", "--find"]:
                return str(tool)
            if command[:2] == ["otool", "-l"]:
                return self.linkage(rpath=str(library_directory))[1]
            if command[:2] == ["otool", "-L"]:
                return self.linkage(dependencies=["/usr/lib/swift/" + library_name])[0]
            if "--resource-library" in command:
                self.executable(app / "Contents/Frameworks" / library_name)
            return ""

        with patch.object(sparkle, "run", side_effect=execute), patch.object(sparkle, "framework_structure", return_value=[]):
            sparkle.prepare_runtime(app)
        copying = [index for index, command in enumerate(commands) if "--resource-library" in command]
        deletion = [index for index, command in enumerate(commands) if command[0] == "install_name_tool"]
        self.assertEqual(len(copying), 1)
        self.assertTrue(deletion and copying[0] < deletion[0])
