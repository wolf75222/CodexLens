#!/usr/bin/env python3
"""Create and validate the stable Sparkle feed using the pinned official tools.

Signing keys enter official Sparkle tools through stdin, never command arguments
or release files. Validation uses the public key shipped in the application.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

REPOSITORY = "https://github.com/wolf75222/CodexLens"
FEED_URL = REPOSITORY + "/releases/latest/download/appcast.xml"
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
IDENTIFIER = "fr.codexlens.inspector"
PRIVATE_KEY_ENV = "SPARKLE_ED25519_PRIVATE_KEY"
MAX_FEED_BYTES = 2 * 1024 * 1024
SIGNATURE_BLOCK = re.compile(
    rb"<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]+={0,2})\nlength: ([0-9]+)\n-->\n\Z"
)


def decoded(value: str, length: int, label: str) -> bytes:
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ValueError(f"Invalid {label}.") from None
    if len(data) != length:
        raise ValueError(f"Invalid {label} length.")
    return data


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_configuration(info: dict) -> None:
    if (info.get("SUFeedURL") != FEED_URL or info.get("SURequireSignedFeed") is not True
            or info.get("SUVerifyUpdateBeforeExtraction") is not True
            or info.get("SUShowReleaseNotes") is not False):
        raise ValueError("Updater configuration must require the fixed signed feed and archives, without HTML release notes.")
    expiration = info.get("SUSignedFeedFailureExpirationInterval")
    if type(expiration) not in {int, float} or expiration != 0:
        raise ValueError("Signed feed verification must never expire or fall back to unsigned content.")


def public_key(info_path: Path) -> str:
    info = plistlib.loads(info_path.read_bytes())
    key = info.get("SUPublicEDKey")
    decoded(key, 32, "public key")
    validate_configuration(info)
    return key


def validate_release(directory: Path, tag: str, key: str) -> tuple[dict, Path]:
    metadata = json.loads((directory / "release-metadata.json").read_text())
    version = metadata.get("version", "")
    build = metadata.get("build", "")
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or tag != "v" + version:
        raise ValueError("Release tag and stable version differ.")
    if not isinstance(build, str) or not re.fullmatch(r"[1-9][0-9]*", build):
        raise ValueError("Release build must be a positive, increasing bundle version.")
    if (metadata.get("schemaVersion") != 1 or metadata.get("bundleIdentifier") != IDENTIFIER
            or metadata.get("architecture") != "arm64" or metadata.get("dirty") is not False
            or not isinstance(metadata.get("sourceCommit"), str)
            or not re.fullmatch(r"[0-9a-f]{40}", metadata.get("sourceCommit", ""))):
        raise ValueError("Release identity, architecture or source revision is invalid.")
    minimum = metadata.get("minimumMacOS", "")
    if not isinstance(minimum, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", minimum) or int(minimum.split(".")[0]) < 14:
        raise ValueError("Release minimum macOS version is invalid.")
    archive = directory / f"CodexLens-{version}-arm64.zip"
    expected = metadata.get("artifacts", {}).get(archive.name, {})
    if archive.is_symlink() or not archive.is_file():
        raise ValueError("The full application ZIP must be a regular release artifact.")
    if (expected.get("bytes") != archive.stat().st_size or expected.get("sha256") != digest(archive)):
        raise ValueError("Archive length or checksum differs from release metadata.")
    with zipfile.ZipFile(archive) as bundle:
        names = bundle.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Archive contains duplicate paths.")
        for name in names:
            path = PurePosixPath(name)
            if (not path.parts or path.is_absolute() or ".." in path.parts or "\\" in name
                    or path.parts[0] not in {"Codex Lens.app", "__MACOSX"}):
                raise ValueError("Archive contains an unsafe or unrelated path.")
        info_entry = bundle.getinfo("Codex Lens.app/Contents/Info.plist")
        if info_entry.file_size > 256 * 1024:
            raise ValueError("Application Info.plist exceeds its size limit.")
        info = plistlib.loads(bundle.read(info_entry))
        expected_info = {"CFBundleIdentifier": IDENTIFIER, "CFBundleExecutable": "CodexLens",
                         "CFBundleShortVersionString": version, "CFBundleVersion": build,
                         "LSMinimumSystemVersion": minimum, "SUPublicEDKey": key,
                         "SUFeedURL": FEED_URL, "SURequireSignedFeed": True,
                         "SUVerifyUpdateBeforeExtraction": True}
        if any(info.get(name) != value for name, value in expected_info.items()) or "LSEnvironment" in info:
            raise ValueError("Archive bundle identity, version or updater configuration differs.")
        validate_configuration(info)
        with bundle.open("Codex Lens.app/Contents/MacOS/CodexLens") as executable:
            header = executable.read(8)
        # Packaging already uses lipo and checks the entire signed bundle. This
        # additional boundary prevents metadata alone from describing an Intel ZIP.
        if len(header) != 8 or struct.unpack("<II", header) != (0xFEEDFACF, 0x0100000C):
            raise ValueError("Archive executable must be a thin arm64 Mach-O binary.")
    return metadata, archive


def signed_content(feed: bytes) -> tuple[bytes, str]:
    if len(feed) > MAX_FEED_BYTES or feed.count(b"<!-- sparkle-signatures:") != 1:
        raise ValueError("Feed signature block is missing, duplicated or oversized.")
    block = SIGNATURE_BLOCK.search(feed)
    if block is None:
        raise ValueError("Feed signature block is malformed.")
    content = feed[:block.start()]
    signature = block.group(1).decode("ascii")
    decoded(signature, 64, "feed signature")
    if int(block.group(2)) != len(content):
        raise ValueError("Signed feed content length differs.")
    return content, signature


def validate_feed(feed: bytes, metadata: dict | None, archive: Path | None) -> tuple[bytes, str, str | None]:
    content, signature = signed_content(feed)
    if b"<!DOCTYPE" in content.upper() or b"<!ENTITY" in content.upper():
        raise ValueError("Feed must not declare entities or a document type.")
    root = ET.fromstring(content)
    channels = root.findall("channel")
    if root.tag != "rss" or root.get("version") != "2.0" or len(channels) != 1:
        raise ValueError("Feed must contain one RSS channel.")
    channel = channels[0]
    items = channel.findall("item")
    if metadata is None:
        if items:
            raise ValueError("Bootstrap feed must not advertise an unsigned legacy update.")
        return content, signature, None
    if len(items) != 1 or archive is None:
        raise ValueError("Feed must advertise exactly one full release archive.")
    item = items[0]
    enclosures = item.findall("enclosure")
    if len(enclosures) != 1 or item.find(f"{{{SPARKLE_NS}}}deltas") is not None:
        raise ValueError("Feed must contain one full ZIP enclosure without deltas.")
    enclosure = enclosures[0]
    expected_url = REPOSITORY + f"/releases/download/v{metadata['version']}/{archive.name}"
    if enclosure.get("url") != expected_url:
        raise ValueError("Feed archive URL must identify the exact HTTPS GitHub release asset.")
    if enclosure.get("length") != str(archive.stat().st_size):
        raise ValueError("Feed enclosure length differs from the release archive.")
    if enclosure.get("type") != "application/octet-stream":
        raise ValueError("Feed enclosure type is invalid.")
    for name, expected in (("version", metadata["build"]), ("shortVersionString", metadata["version"])):
        element = item.find(f"{{{SPARKLE_NS}}}{name}")
        values = [v for v in (element.text if element is not None else None,
                             enclosure.get(f"{{{SPARKLE_NS}}}{name}")) if v is not None]
        if not values or any(value != expected for value in values):
            raise ValueError("Feed bundle version differs from the verified release.")
    if item.findtext(f"{{{SPARKLE_NS}}}minimumSystemVersion") != metadata["minimumMacOS"]:
        raise ValueError("Feed minimum macOS version differs.")
    if item.findtext(f"{{{SPARKLE_NS}}}hardwareRequirements") != "arm64":
        raise ValueError("Feed hardware requirement must be arm64.")
    if item.find(f"{{{SPARKLE_NS}}}releaseNotesLink") is not None:
        raise ValueError("This update channel does not load external release notes.")
    archive_signature = enclosure.get(f"{{{SPARKLE_NS}}}edSignature")
    decoded(archive_signature, 64, "archive signature")
    return content, signature, archive_signature


PUBLIC_VERIFIER = """import Foundation
import CryptoKit
let args = CommandLine.arguments
do {
    guard args.count == 4, let key = Data(base64Encoded: args[1]),
          let signature = Data(base64Encoded: args[3]) else { exit(1) }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
    let content = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    guard publicKey.isValidSignature(signature, for: content) else { exit(1) }
} catch { exit(1) }
"""


def verify_signature(key: str, signature: str, file: Path) -> None:
    decoded(key, 32, "public key")
    decoded(signature, 64, "signature")
    environment = {k: v for k, v in os.environ.items() if k != PRIVATE_KEY_ENV}
    result = subprocess.run(["/usr/bin/swift", "-e", PUBLIC_VERIFIER, key, str(file), signature],
                            capture_output=True, env=environment, timeout=120)
    if result.returncode:
        raise ValueError("Ed25519 verification failed against the application's public key.")


def validate_signatures(feed_path: Path, metadata: dict | None, archive: Path | None, key: str) -> None:
    content, signature, archive_signature = validate_feed(feed_path.read_bytes(), metadata, archive)
    with tempfile.TemporaryDirectory(prefix="codex-lens-feed-verification.") as scratch:
        content_path = Path(scratch) / "signed-content.xml"
        content_path.write_bytes(content)
        verify_signature(key, signature, content_path)
    if archive is not None and archive_signature is not None:
        verify_signature(key, archive_signature, archive)


def signing_key() -> str:
    secret = os.environ.get(PRIVATE_KEY_ENV, "").strip()
    try:
        data = base64.b64decode(secret, validate=True)
    except ValueError:
        raise ValueError("The Sparkle signing secret is invalid.") from None
    # Exact Sparkle 2.10 formats: a modern 32-byte seed or legacy 96-byte keypair.
    if len(data) not in {32, 96}:
        raise ValueError("The Sparkle signing secret is missing or has an unsupported format.")
    return secret


def run_signer(tool: Path, arguments: list[str], secret: str) -> None:
    if not tool.is_file() or not os.access(tool, os.X_OK):
        raise ValueError("Official Sparkle signing tool is unavailable.")
    environment = {k: v for k, v in os.environ.items() if k != PRIVATE_KEY_ENV}
    result = subprocess.run([str(tool), "--ed-key-file", "-", *arguments],
                            input=secret + "\n", text=True, capture_output=True,
                            env=environment, timeout=300)
    if result.returncode:
        # Some official error messages repeat invalid key input. Never relay the
        # subprocess output, even though our format check runs before signing.
        raise ValueError(f"Official Sparkle {tool.name} failed; no update was published.")


def write_checksums(directory: Path) -> None:
    files = sorted(directory.iterdir())
    if any(path.is_symlink() or not path.is_file() for path in files):
        raise ValueError("Release directory must contain only regular artifact files.")
    (directory / "CHECKSUMS.sha256").write_text("".join(
        f"{digest(path)}  {path.name}\n" for path in files if path.name != "CHECKSUMS.sha256"))


def create_release(directory: Path, tag: str, info: Path, tools: Path) -> Path:
    key = public_key(info)
    metadata, archive = validate_release(directory, tag, key)
    destination = directory / "appcast.xml"
    if destination.exists() or destination.is_symlink():
        raise ValueError("An appcast already exists; published update feeds are not overwritten here.")
    secret = signing_key()
    with tempfile.TemporaryDirectory(prefix="codex-lens-appcast.") as scratch:
        stage = Path(scratch)
        shutil.copy2(archive, stage / archive.name)
        feed = stage / "appcast.xml"
        run_signer(tools / "generate_appcast", ["--maximum-deltas", "0", "--maximum-versions", "1",
                   "--versions", metadata["build"], "--download-url-prefix",
                   REPOSITORY + "/releases/download/" + tag + "/", "-o", str(feed), str(stage)], secret)
        # Explicitly sign even if the generator's archive inference changes. The
        # public-key verification below rejects a missing/wrong enclosure signature.
        run_signer(tools / "sign_update", ["-p", str(feed)], secret)
        validate_signatures(feed, metadata, archive, key)
        shutil.copy2(feed, destination)
    write_checksums(directory)
    return destination


def create_empty(destination: Path, info: Path, tools: Path) -> None:
    key = public_key(info)
    if destination.exists() or destination.is_symlink():
        raise ValueError("Bootstrap output already exists.")
    secret = signing_key()
    with tempfile.TemporaryDirectory(prefix="codex-lens-bootstrap-feed.") as scratch:
        feed = Path(scratch) / "appcast.xml"
        feed.write_text('<?xml version="1.0" encoding="UTF-8"?>\n'
                        '<rss version="2.0"><channel><title>Codex Lens</title></channel></rss>\n')
        run_signer(tools / "sign_update", ["-p", str(feed)], secret)
        validate_signatures(feed, None, None, key)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(feed, destination)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["release", "validate", "bootstrap-empty"])
    parser.add_argument("--info-plist", type=Path, default=Path("Support/Info.plist"))
    parser.add_argument("--tools", type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--tag")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if args.command == "bootstrap-empty":
        if args.tools is None or args.output is None:
            parser.error("bootstrap-empty requires --tools and --output")
        create_empty(args.output, args.info_plist, args.tools)
        print("Validated signed bootstrap feed; no update is advertised.")
    else:
        if args.artifacts is None or args.tag is None:
            parser.error("release and validate require --artifacts and --tag")
        if args.command == "release":
            if args.tools is None:
                parser.error("release requires --tools")
            create_release(args.artifacts, args.tag, args.info_plist, args.tools)
        else:
            key = public_key(args.info_plist)
            metadata, archive = validate_release(args.artifacts, args.tag, key)
            validate_signatures(args.artifacts / "appcast.xml", metadata, archive, key)
        print("Validated signed update feed and full release ZIP.")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, ET.ParseError, zipfile.BadZipFile, OSError, subprocess.TimeoutExpired) as error:
        # Exceptions from key decoding/signing are intentionally sanitized above.
        print(f"Update feed validation failed: {error}", file=sys.stderr)
        sys.exit(1)
