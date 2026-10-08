import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / file)
    value = importlib.util.module_from_spec(spec)
    # Direct spec loading must expose sibling script modules just like running
    # `python3 scripts/validate-release.py` does.
    sys.path.insert(0, str(ROOT / "scripts"))
    try:
        spec.loader.exec_module(value)
    finally:
        sys.path.pop(0)
    return value


package = module("package_release", "package_release.py")
validator = module("validate_release", "validate-release.py")


class ReleaseBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.artifacts = self.root / "artifacts"
        self.artifacts.mkdir()
        self.app = self.root / "Codex Lens.app"
        (self.app / "Contents").mkdir(parents=True)
        self.info = {"CFBundleIdentifier": "fr.codexlens.inspector", "CFBundleExecutable": "CodexLens",
                     "CFBundleName": "Codex Lens", "CFBundleDisplayName": "Codex Lens",
                     "CFBundleShortVersionString": "0.41.0", "CFBundleVersion": "75"}
        self.save()

    def save(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def test_production_bundle_and_version_are_identified(self):
        self.assertEqual(package.read_bundle(self.app)["CFBundleShortVersionString"], "0.41.0")

    def test_qa_environment_is_never_packaged(self):
        self.info["LSEnvironment"] = {"LENS_CODEX_HOME": "/anonymous/fixture"}
        self.save()
        with self.assertRaisesRegex(ValueError, "QA"):
            package.read_bundle(self.app)

    def test_test_name_is_rejected_by_packaging_and_installer_validation(self):
        for key in ("CFBundleName", "CFBundleDisplayName"):
            with self.subTest(key=key):
                self.info[key] = "Codex Lens (test)"
                self.save()
                with self.assertRaisesRegex(ValueError, "application name"):
                    package.read_bundle(self.app)
                with self.assertRaisesRegex(ValueError, "application name"):
                    validator.bundle_checks(self.app, {})
                self.info[key] = "Codex Lens"

    def test_missing_production_name_is_rejected(self):
        del self.info["CFBundleDisplayName"]
        self.save()
        with self.assertRaisesRegex(ValueError, "application name"):
            package.read_bundle(self.app)

    def test_symbolic_link_cannot_impersonate_a_bundle(self):
        link = self.root / "Linked.app"
        link.symlink_to(self.app)
        with self.assertRaises(ValueError):
            package.read_bundle(link)

    def test_version_cannot_inject_a_release_path(self):
        self.info["CFBundleShortVersionString"] = "../other"
        self.save()
        with self.assertRaises(ValueError):
            package.read_bundle(self.app)

    def checksums(self, files):
        (self.artifacts / "CHECKSUMS.sha256").write_text("".join(
            hashlib.sha256(data).hexdigest() + "  " + name + "\n" for name, data in files.items()))

    def test_checksums_cover_exact_artifacts_and_detect_tampering(self):
        original = {"application.zip": b"example", "metadata.json": b"{}"}
        for name, data in original.items():
            (self.artifacts / name).write_bytes(data)
        self.checksums(original)
        validator.checksum_files(self.artifacts)
        (self.artifacts / "application.zip").write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "mismatch"):
            validator.checksum_files(self.artifacts)

    def test_unlisted_file_is_rejected(self):
        (self.artifacts / "metadata.json").write_bytes(b"{}")
        self.checksums({"metadata.json": b"{}"})
        (self.artifacts / "unexpected.txt").write_text("unexpected")
        with self.assertRaisesRegex(ValueError, "exact artifact"):
            validator.checksum_files(self.artifacts)

    def test_checksum_path_cannot_escape_release_directory(self):
        (self.artifacts / "CHECKSUMS.sha256").write_text("0" * 64 + "  ../outside\n")
        with self.assertRaisesRegex(ValueError, "Unsafe"):
            validator.checksum_files(self.artifacts)

    def test_release_directory_cannot_include_a_link_or_hidden_directory(self):
        self.checksums({})
        (self.artifacts / "hidden-data").mkdir()
        with self.assertRaisesRegex(ValueError, "regular artifact"):
            validator.checksum_files(self.artifacts)

    def test_mount_identity_accepts_canonical_system_path_alias(self):
        mount = self.root / "mount"
        mount.mkdir()
        alias = self.root / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        attached = {"system-entities": [{"dev-entry": "/dev/fixture", "mount-point": str(mount)}]}
        self.assertEqual(validator.owned_mount_device(attached, alias / "mount"), "/dev/fixture")

    def test_unrelated_mount_path_is_not_accepted(self):
        attached = {"system-entities": [{"dev-entry": "/dev/unrelated", "mount-point": str(self.root / "other")}]}
        with self.assertRaises(ValueError):
            validator.owned_mount_device(attached, self.root / "mount")
