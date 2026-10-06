import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("update_appcast", ROOT / "scripts/update_appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)

# Public, pre-signed offline test vector. No private signing key is committed.
PUBLIC_KEY = "GX9rI+FshTLGq8g4+s1ep4m+DHaykgM0A5v6iz02jWE="
TEST_CONTENT = b"Codex Lens signature fixture\n"
TEST_SIGNATURE = "9Wz4jwSgOSlmceyKbsFZMkfl6WrrYdW4WGM/NORVIbzzGBG9ga9ee3j/IUa9YKQDA4MsQS0+CopOpKZxcBaeBg=="
STRUCTURAL_SIGNATURE = base64.b64encode(bytes(64)).decode()
S = "{" + appcast.SPARKLE_NS + "}"


class AppcastBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.archive = self.root / "CodexLens-0.42.0-arm64.zip"
        self.info_path = self.root / "Info.plist"
        self.info = {"CFBundleIdentifier": appcast.IDENTIFIER, "CFBundleExecutable": "CodexLens",
                     "CFBundleShortVersionString": "0.42.0", "CFBundleVersion": "76",
                     "LSMinimumSystemVersion": "14.0", "SUPublicEDKey": PUBLIC_KEY,
                     "SUFeedURL": appcast.FEED_URL, "SURequireSignedFeed": True,
                     "SUVerifyUpdateBeforeExtraction": True, "SUShowReleaseNotes": False,
                     "SUSignedFeedFailureExpirationInterval": 0}
        self.metadata = {"schemaVersion": 1, "version": "0.42.0", "build": "76",
                         "bundleIdentifier": appcast.IDENTIFIER, "architecture": "arm64",
                         "minimumMacOS": "14.0", "sourceCommit": "a" * 40,
                         "dirty": False, "artifacts": {}}
        self.save_archive()
        self.info_path.write_bytes(plistlib.dumps(self.info))

    def save_archive(self, cpu=0x0100000C, extra=None):
        with zipfile.ZipFile(self.archive, "w") as archive:
            archive.writestr("Codex Lens.app/Contents/Info.plist", plistlib.dumps(self.info))
            archive.writestr("Codex Lens.app/Contents/MacOS/CodexLens", struct.pack("<II", 0xFEEDFACF, cpu))
            if extra:
                archive.writestr(extra, b"unrelated")
        self.metadata["artifacts"][self.archive.name] = {
            "bytes": self.archive.stat().st_size,
            "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest()}
        self.save_metadata()

    def save_metadata(self):
        (self.root / "release-metadata.json").write_text(json.dumps(self.metadata))

    def release(self):
        return appcast.validate_release(self.root, "v0.42.0", PUBLIC_KEY)

    def xml(self):
        root = ET.Element("rss", {"version": "2.0"})
        channel = ET.SubElement(root, "channel")
        ET.SubElement(channel, "title").text = "Codex Lens"
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, S + "version").text = "76"
        ET.SubElement(item, S + "shortVersionString").text = "0.42.0"
        ET.SubElement(item, S + "minimumSystemVersion").text = "14.0"
        ET.SubElement(item, S + "hardwareRequirements").text = "arm64"
        ET.SubElement(item, "enclosure", {
            "url": appcast.REPOSITORY + "/releases/download/v0.42.0/" + self.archive.name,
            "length": str(self.archive.stat().st_size), "type": "application/octet-stream",
            S + "edSignature": STRUCTURAL_SIGNATURE})
        return root

    @staticmethod
    def signed_xml(root):
        data = ET.tostring(root, encoding="utf-8", xml_declaration=True) + b"\n"
        return data + ("<!-- sparkle-signatures:\nedSignature: " + STRUCTURAL_SIGNATURE
                       + "\nlength: " + str(len(data)) + "\n-->\n").encode()

    def feed(self, root=None):
        return appcast.validate_feed(self.signed_xml(root if root is not None else self.xml()),
                                     self.metadata, self.archive)

    def test_verified_release_identity_and_feed(self):
        self.assertEqual(self.release()[1], self.archive)
        self.assertEqual(appcast.public_key(self.info_path), PUBLIC_KEY)
        self.assertEqual(self.feed()[2], STRUCTURAL_SIGNATURE)

    def test_wrong_tag_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "tag"):
            appcast.validate_release(self.root, "v0.43.0", PUBLIC_KEY)

    def test_dirty_or_missing_source_revision_is_rejected(self):
        for name, value in [("dirty", True), ("sourceCommit", ""), ("bundleIdentifier", "another.app")]:
            with self.subTest(name=name):
                original = self.metadata[name]
                self.metadata[name] = value
                self.save_metadata()
                with self.assertRaises(ValueError):
                    self.release()
                self.metadata[name] = original

    def test_archive_tamper_is_rejected(self):
        self.archive.write_bytes(self.archive.read_bytes() + b"tampered")
        with self.assertRaisesRegex(ValueError, "length or checksum"):
            self.release()

    def test_wrong_metadata_architecture_is_rejected(self):
        self.metadata["architecture"] = "x86_64"
        self.save_metadata()
        with self.assertRaisesRegex(ValueError, "architecture"):
            self.release()

    def test_intel_executable_cannot_be_relabelled_arm64(self):
        self.save_archive(cpu=0x01000007)
        with self.assertRaisesRegex(ValueError, "arm64 Mach-O"):
            self.release()

    def test_wrong_bundle_version_is_rejected(self):
        self.info["CFBundleVersion"] = "75"
        self.save_archive()
        with self.assertRaisesRegex(ValueError, "bundle identity, version"):
            self.release()

    def test_wrong_embedded_public_key_is_rejected(self):
        self.info["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()
        self.save_archive()
        with self.assertRaisesRegex(ValueError, "updater configuration"):
            self.release()

    def test_qa_bundle_is_not_an_update(self):
        self.info["LSEnvironment"] = {"LENS_CODEX_HOME": "/anonymous/fixture"}
        self.save_archive()
        with self.assertRaises(ValueError):
            self.release()

    def test_feed_signature_verification_cannot_expire(self):
        for value in [20 * 86400, -1, False, "0", None]:
            with self.subTest(value=value):
                if value is None:
                    self.info.pop("SUSignedFeedFailureExpirationInterval", None)
                else:
                    self.info["SUSignedFeedFailureExpirationInterval"] = value
                self.info_path.write_bytes(plistlib.dumps(self.info))
                self.save_archive()
                with self.assertRaisesRegex(ValueError, "must never expire"):
                    appcast.public_key(self.info_path)
                with self.assertRaisesRegex(ValueError, "must never expire"):
                    self.release()

    def test_html_release_notes_must_remain_disabled(self):
        for value in [True, 0, None]:
            with self.subTest(value=value):
                if value is None:
                    self.info.pop("SUShowReleaseNotes", None)
                else:
                    self.info["SUShowReleaseNotes"] = value
                self.info_path.write_bytes(plistlib.dumps(self.info))
                self.save_archive()
                with self.assertRaisesRegex(ValueError, "without HTML release notes"):
                    appcast.public_key(self.info_path)
                with self.assertRaisesRegex(ValueError, "without HTML release notes"):
                    self.release()

    def test_archive_paths_cannot_escape_or_add_another_application(self):
        for name in ["../escape", "/absolute", "Other.app/Contents/Info.plist", "Codex Lens.app/../escape"]:
            with self.subTest(name=name):
                self.save_archive(extra=name)
                with self.assertRaisesRegex(ValueError, "unsafe or unrelated"):
                    self.release()

    def test_unsafe_or_wrong_release_asset_urls_are_rejected(self):
        for url in ["http://github.com/wolf75222/CodexLens/releases/download/v0.42.0/file.zip",
                    "https://evil.example/application.zip",
                    appcast.REPOSITORY + "/releases/download/v0.41.0/" + self.archive.name,
                    appcast.REPOSITORY + "/releases/download/v0.42.0/" + self.archive.name + "?token=value"]:
            with self.subTest(url=url):
                root = self.xml()
                root.find("./channel/item/enclosure").set("url", url)
                with self.assertRaisesRegex(ValueError, "HTTPS GitHub"):
                    self.feed(root)

    def test_wrong_enclosure_length_is_rejected(self):
        root = self.xml()
        root.find("./channel/item/enclosure").set("length", "1")
        with self.assertRaisesRegex(ValueError, "enclosure length"):
            self.feed(root)

    def test_wrong_feed_version_is_rejected(self):
        root = self.xml()
        root.find("./channel/item/" + S + "version").text = "75"
        with self.assertRaisesRegex(ValueError, "bundle version"):
            self.feed(root)

    def test_conflicting_legacy_and_modern_version_fields_are_rejected(self):
        root = self.xml()
        root.find("./channel/item/enclosure").set(S + "version", "75")
        with self.assertRaisesRegex(ValueError, "bundle version"):
            self.feed(root)

    def test_missing_or_wrong_hardware_requirement_is_rejected(self):
        root = self.xml()
        root.find("./channel/item/" + S + "hardwareRequirements").text = "x86_64"
        with self.assertRaisesRegex(ValueError, "hardware"):
            self.feed(root)

    def test_wrong_minimum_os_is_rejected(self):
        root = self.xml()
        root.find("./channel/item/" + S + "minimumSystemVersion").text = "12.0"
        with self.assertRaisesRegex(ValueError, "minimum macOS"):
            self.feed(root)

    def test_unintended_external_release_notes_are_rejected(self):
        root = self.xml()
        ET.SubElement(root.find("./channel/item"), S + "releaseNotesLink").text = "https://example.com/notes"
        with self.assertRaisesRegex(ValueError, "external release notes"):
            self.feed(root)

    def test_missing_archive_signature_is_rejected(self):
        root = self.xml()
        del root.find("./channel/item/enclosure").attrib[S + "edSignature"]
        with self.assertRaisesRegex(ValueError, "archive signature"):
            self.feed(root)

    def test_unsigned_duplicated_or_changed_length_feed_is_rejected(self):
        feed = self.signed_xml(self.xml())
        for invalid in [ET.tostring(self.xml()), feed + feed, feed.replace(b"length: ", b"length: 1")]:
            with self.subTest(invalid=invalid[:25]):
                with self.assertRaises(ValueError):
                    appcast.signed_content(invalid)

    def test_bootstrap_feed_has_no_legacy_update(self):
        with self.assertRaisesRegex(ValueError, "legacy update"):
            appcast.validate_feed(self.signed_xml(self.xml()), None, None)
        empty = ET.fromstring('<rss version="2.0"><channel><title>Codex Lens</title></channel></rss>')
        self.assertIsNone(appcast.validate_feed(self.signed_xml(empty), None, None)[2])

    def test_missing_or_malformed_signing_secret_fails_closed_without_echo(self):
        for secret in ["", "do not expose this", base64.b64encode(bytes(64)).decode()]:
            with self.subTest(secret_length=len(secret)), patch.dict(os.environ, {appcast.PRIVATE_KEY_ENV: secret}):
                with self.assertRaises(ValueError) as failure:
                    appcast.signing_key()
                if secret:
                    self.assertNotIn(secret, str(failure.exception))

    def test_supported_official_seed_and_legacy_formats(self):
        for count in [32, 96]:
            encoded = base64.b64encode(bytes(count)).decode()
            with patch.dict(os.environ, {appcast.PRIVATE_KEY_ENV: encoded}):
                self.assertEqual(appcast.signing_key(), encoded)

    def test_signer_receives_key_via_stdin_and_redacts_failures(self):
        tool = self.root / "sign_update"
        tool.write_text("#!/bin/sh\nexit 1\n")
        tool.chmod(0o700)
        secret = "sensitive marker"
        with patch.dict(os.environ, {appcast.PRIVATE_KEY_ENV: secret}), patch.object(appcast.subprocess, "run") as run:
            run.return_value.returncode = 1
            run.return_value.stdout = secret
            run.return_value.stderr = secret
            with self.assertRaises(ValueError) as failure:
                appcast.run_signer(tool, ["-p", "archive.zip"], secret)
            args, kwargs = run.call_args
            self.assertNotIn(secret, " ".join(args[0]))
            self.assertEqual(kwargs["input"], secret + "\n")
            self.assertNotIn(appcast.PRIVATE_KEY_ENV, kwargs["env"])
            self.assertNotIn(secret, str(failure.exception))

    def test_crypto_verifier_never_inherits_signing_secret(self):
        with patch.dict(os.environ, {appcast.PRIVATE_KEY_ENV: "sensitive marker"}), patch.object(appcast.subprocess, "run") as run:
            run.return_value.returncode = 0
            appcast.verify_signature(PUBLIC_KEY, TEST_SIGNATURE, self.archive)
            self.assertNotIn(appcast.PRIVATE_KEY_ENV, run.call_args.kwargs["env"])

    @unittest.skipUnless(sys.platform == "darwin" and Path("/usr/bin/swift").is_file(), "CryptoKit verification requires macOS Swift")
    def test_actual_ed25519_verification_accepts_vector_and_rejects_tamper(self):
        content = self.root / "signed-content.txt"
        content.write_bytes(TEST_CONTENT)
        appcast.verify_signature(PUBLIC_KEY, TEST_SIGNATURE, content)
        content.write_bytes(TEST_CONTENT + b"tampered")
        with self.assertRaisesRegex(ValueError, "Ed25519 verification"):
            appcast.verify_signature(PUBLIC_KEY, TEST_SIGNATURE, content)
        content.write_bytes(TEST_CONTENT)
        with self.assertRaisesRegex(ValueError, "Ed25519 verification"):
            appcast.verify_signature(base64.b64encode(bytes(32)).decode(), TEST_SIGNATURE, content)

    def test_checksums_include_signed_feed_and_all_original_artifacts(self):
        (self.root / "appcast.xml").write_bytes(self.signed_xml(self.xml()))
        appcast.write_checksums(self.root)
        checksums = (self.root / "CHECKSUMS.sha256").read_text()
        for name in ["appcast.xml", "release-metadata.json", self.archive.name, "Info.plist"]:
            self.assertIn("  " + name + "\n", checksums)


if __name__ == "__main__":
    unittest.main()
