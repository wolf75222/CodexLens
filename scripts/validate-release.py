#!/usr/bin/env python3
"""Validate checksums, installer layout, app signatures, resources and symbols."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import zipfile

from sparkle_bundle import validate_embedded


def run(args: list[str]) -> bytes:
    result = subprocess.run(args, capture_output=True)
    if result.returncode:
        raise RuntimeError(args[0] + ": " + result.stderr.decode(errors="replace")[-3000:])
    return result.stdout


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def owned_mount_device(attached: dict, mount: Path) -> str:
    devices = [item["dev-entry"] for item in attached["system-entities"]
               if item.get("mount-point") and Path(item["mount-point"]).resolve() == mount.resolve()]
    if len(devices) != 1:
        raise ValueError("Cannot identify the owned installer mount.")
    return devices[0]


def checksum_files(directory: Path) -> None:
    if any(p.is_symlink() or not p.is_file() for p in directory.iterdir()):
        raise ValueError("Release directory must contain only regular artifact files.")
    checked = set()
    for line in (directory / "CHECKSUMS.sha256").read_text().splitlines():
        expected, name = line.split("  ", 1)
        if not re.fullmatch(r"[0-9a-f]{64}", expected) or Path(name).name != name or name in checked:
            raise ValueError("Unsafe or repeated checksum entry.")
        if digest(directory / name) != expected:
            raise ValueError("Checksum mismatch: " + name)
        checked.add(name)
    actual = {p.name for p in directory.iterdir() if p.is_file() and p.name != "CHECKSUMS.sha256"}
    if checked != actual:
        raise ValueError("Checksums do not cover the exact artifact set.")


def bundle_checks(app: Path, metadata: dict) -> dict:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != "fr.codexlens.inspector" or "LSEnvironment" in info:
        raise ValueError("Release contains QA configuration.")
    if info.get("CFBundleShortVersionString") != metadata["version"] or info.get("CFBundleVersion") != metadata["build"]:
        raise ValueError("Bundle version differs from release metadata.")
    if info.get("LSMinimumSystemVersion") != metadata["minimumMacOS"]:
        raise ValueError("Minimum OS differs from release metadata.")
    exe = app / "Contents/MacOS/CodexLens"
    if not os.access(exe, os.X_OK) or run(["lipo", "-archs", str(exe)]).decode().strip() != "arm64":
        raise ValueError("Executable permissions or architecture are incorrect.")
    if metadata["uuid"] not in run(["xcrun", "dwarfdump", "--uuid", str(exe)]).decode():
        raise ValueError("Release executable UUID differs.")
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    validate_embedded(app)
    build = json.loads((app / "Contents/Resources/BuildInfo.json").read_text())
    if build.get("sourceCommit") != metadata["sourceCommit"] or build.get("dirty") != metadata["dirty"]:
        raise ValueError("Bundle build provenance differs.")
    resources = app / "Contents/Resources"
    required = ["CodexLens.icns", "CodexLens-Dark.icns", "CodexLens-Light.icns", "Localizations/en.json", "THIRD_PARTY_NOTICES.txt", "Sparkle-LICENSE.txt"]
    if not all((resources / name).is_file() for name in required):
        raise ValueError("Release resources are missing.")
    return {str(p.relative_to(app)): digest(p) for p in sorted(app.rglob("*")) if p.is_file()}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    directory = args.directory.resolve()
    checksum_files(directory)
    metadata = json.loads((directory / "release-metadata.json").read_text())
    if not re.fullmatch(r"\d+\.\d+\.\d+", metadata["version"]):
        raise ValueError("Invalid release version.")
    prefix = f"CodexLens-{metadata['version']}-arm64"
    expected_artifacts = {prefix + suffix for suffix in [".dmg", ".zip", "-symbols.zip"]}
    if set(metadata["artifacts"]) != expected_artifacts or metadata.get("architecture") != "arm64":
        raise ValueError("Unexpected release artifact set or architecture.")
    for name, properties in metadata["artifacts"].items():
        if Path(name).name != name or digest(directory / name) != properties["sha256"]:
            raise ValueError("Metadata artifact digest differs.")
    with tempfile.TemporaryDirectory(prefix="codex-lens-verify.") as scratch:
        root = Path(scratch).resolve()
        for suffix in [".zip", "-symbols.zip"]:
            archive = directory / (prefix + suffix)
            with zipfile.ZipFile(archive) as zipped:
                if zipped.testzip() is not None or any(Path(n).is_absolute() or ".." in Path(n).parts for n in zipped.namelist()):
                    raise ValueError("Invalid archive structure.")
            run(["ditto", "-x", "-k", str(archive), str(root)])
        app = root / "Codex Lens.app"
        zip_bytes = bundle_checks(app, metadata)
        symbols = root / "Codex Lens.app.dSYM/Contents/Resources/DWARF/CodexLens"
        if metadata["uuid"] not in run(["xcrun", "dwarfdump", "--uuid", str(symbols)]).decode():
            raise ValueError("Symbols do not match the application.")
        dmg = directory / (prefix + ".dmg")
        run(["hdiutil", "verify", str(dmg)])
        mount = root / "mount"
        mount.mkdir()
        attached = plistlib.loads(run(["hdiutil", "attach", "-readonly", "-nobrowse", "-plist", "-mountpoint", str(mount), str(dmg)]))
        # All devices in this attach response belong to our newly attached
        # image. Even a malformed mount response must be detached on failure.
        attached_devices = [item["dev-entry"] for item in attached["system-entities"] if item.get("dev-entry")]
        device = attached_devices[0] if attached_devices else None
        try:
            device = owned_mount_device(attached, mount)
            if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
                raise ValueError("Installer Applications link is incorrect.")
            if not (mount / ".DS_Store").is_file():
                raise ValueError("Installer Finder layout is missing.")
            if bundle_checks(mount / "Codex Lens.app", metadata) != zip_bytes:
                raise ValueError("DMG and ZIP contain different app bytes.")
            from ds_store import DSStore
            with DSStore.open(str(mount / ".DS_Store"), "r") as store:
                if tuple(store["Codex Lens.app"]["Iloc"]) != (170, 220) or tuple(store["Applications"]["Iloc"]) != (470, 220):
                    raise ValueError("Installer icon positions differ.")
            if metadata["notarized"]:
                run(["xcrun", "stapler", "validate", str(mount / "Codex Lens.app")])
                run(["xcrun", "stapler", "validate", str(dmg)])
        finally:
            if device: run(["hdiutil", "detach", device])
    print("Release verified: exact checksums, signed app, matching dSYM and drag-to-Applications DMG.")


if __name__ == "__main__":
    main()
