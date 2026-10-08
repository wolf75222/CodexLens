#!/usr/bin/env python3
"""Create and verify a drag-to-Applications DMG from the actual signed bundle."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
IDENTIFIER = "fr.codexlens.inspector"


def run(args: list[str], **kwargs) -> str:
    result = subprocess.run(args, check=True, capture_output=True, text=True, **kwargs)
    return result.stdout.strip()


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def validate_production_identity(info: dict) -> None:
    if info.get("CFBundleIdentifier") != IDENTIFIER or "LSEnvironment" in info:
        raise ValueError("Refusing a QA bundle or an unexpected bundle identifier.")
    if any(info.get(key) != "Codex Lens" for key in ("CFBundleName", "CFBundleDisplayName")):
        raise ValueError("Refusing a QA or unexpected application name.")


def read_bundle(app: Path) -> dict:
    if app.is_symlink() or not app.is_dir() or app.suffix != ".app":
        raise ValueError("Expected a real .app directory, not a symbolic link.")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    validate_production_identity(info)
    version = info.get("CFBundleShortVersionString", "")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Bundle version must be a three-part release version.")
    if info.get("CFBundleExecutable") != "CodexLens":
        raise ValueError("Unexpected bundle executable.")
    return info


def notarize(path: Path, profile: str) -> None:
    result = json.loads(run(["xcrun", "notarytool", "submit", str(path),
                             "--keychain-profile", profile, "--wait", "--output-format", "json"]))
    if result.get("status") != "Accepted":
        raise ValueError("Notarization did not finish with Accepted status.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, help="Package an already built app; otherwise build Release with symbols.")
    parser.add_argument("--output", type=Path, default=ROOT / "dist/release")
    parser.add_argument("--allow-dirty", action="store_true", help="Local packaging preview only; metadata records the dirty state.")
    args = parser.parse_args()
    if args.app is None:
        app = Path(os.environ.get("LENS_APP_PATH", ROOT / "dist/Codex Lens.app")).absolute()
        subprocess.run(["bash", str(ROOT / "scripts/build.sh"), "--profile"], check=True)
    else:
        app = args.app.expanduser().absolute()
    info = read_bundle(app)
    version = info["CFBundleShortVersionString"]
    output = args.output.expanduser().absolute()
    if app.resolve() == output.resolve() or app.resolve() in output.resolve().parents:
        raise ValueError("Output directory must not be inside the application.")
    if output.exists() and any(output.iterdir()):
        raise ValueError("Output directory is not empty; use a fresh directory.")
    if output.is_symlink():
        raise ValueError("Output directory must not be a symbolic link.")
    build_info = json.loads((app / "Contents/Resources/BuildInfo.json").read_text())
    if (build_info.get("dirty") or not build_info.get("sourceCommit")) and not args.allow_dirty:
        raise ValueError("Build is not tied to a clean Git revision; --allow-dirty is for local previews only.")
    if build_info.get("version") != version:
        raise ValueError("Build metadata and bundle version differ.")
    expected_commit = os.environ.get("GITHUB_SHA")
    if expected_commit and build_info.get("sourceCommit") != expected_commit:
        raise ValueError("Build does not match the workflow source revision.")
    tag = os.environ.get("GITHUB_REF", "")
    if tag.startswith("refs/tags/") and tag != "refs/tags/v" + version:
        raise ValueError("Git tag and app version differ.")
    exe = app / "Contents/MacOS/CodexLens"
    if run(["lipo", "-archs", str(exe)]) != "arm64":
        raise ValueError("The current release channel is Apple Silicon (arm64) only.")
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    uuid_line = run(["xcrun", "dwarfdump", "--uuid", str(exe)])
    uuid = re.search(r"UUID: ([0-9A-F-]+)", uuid_line).group(1)
    dsym = app.with_suffix(".app.dSYM")
    symbols = dsym / "Contents/Resources/DWARF/CodexLens"
    if uuid not in run(["xcrun", "dwarfdump", "--uuid", str(symbols)]):
        raise ValueError("The executable and dSYM UUIDs differ.")
    profile = os.environ.get("LENS_NOTARY_PROFILE")
    prefix = f"CodexLens-{version}-arm64"
    with tempfile.TemporaryDirectory(prefix="codex-lens-release.") as scratch:
        stage = Path(scratch)
        staged_app = stage / "Codex Lens.app"
        run(["ditto", str(app), str(staged_app)])
        if profile:
            notarization_zip = stage / "notarization.zip"
            run(["ditto", "-c", "-k", "--keepParent", str(staged_app), str(notarization_zip)])
            notarize(notarization_zip, profile)
            run(["xcrun", "stapler", "staple", str(staged_app)])
            run(["xcrun", "stapler", "validate", str(staged_app)])
        artifacts = stage / "artifacts"
        artifacts.mkdir()
        app_zip = artifacts / (prefix + ".zip")
        run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(staged_app), str(app_zip)])
        symbol_zip = artifacts / (prefix + "-symbols.zip")
        run(["ditto", "-c", "-k", "--keepParent", str(dsym), str(symbol_zip)])
        import dmgbuild
        dmg = artifacts / (prefix + ".dmg")
        dmgbuild.build_dmg(str(dmg), "Codex Lens " + version, settings={
            "format": "UDZO", "filesystem": "HFS+",
            "files": [str(staged_app)], "symlinks": {"Applications": "/Applications"},
            "background": str(ROOT / "Assets/Installer/background.png"),
            "icon": str(ROOT / "Assets/CodexLens.icns"),
            "window_rect": ((200, 160), (640, 400)), "default_view": "icon-view",
            "show_status_bar": False, "show_toolbar": False, "show_sidebar": False,
            "show_tab_view": False, "show_pathbar": False, "arrange_by": None,
            "icon_locations": {"Codex Lens.app": (170, 220), "Applications": (470, 220)},
            "icon_size": 104, "text_size": 14, "label_pos": "bottom",
        })
        if profile:
            notarize(dmg, profile)
            run(["xcrun", "stapler", "staple", str(dmg)])
            run(["xcrun", "stapler", "validate", str(dmg)])
        metadata = {"schemaVersion": 1, "version": version, "build": info["CFBundleVersion"],
                    "bundleIdentifier": IDENTIFIER, "architecture": "arm64", "minimumMacOS": info["LSMinimumSystemVersion"],
                    "sourceCommit": build_info.get("sourceCommit"), "dirty": build_info.get("dirty"),
                    "uuid": uuid, "notarized": bool(profile),
                    "signing": "Developer ID" if profile else "See app code signature; community CI uses ad hoc signing",
                    "artifacts": {p.name: {"sha256": digest(p), "bytes": p.stat().st_size}
                                  for p in [dmg, app_zip, symbol_zip]}}
        (artifacts / "release-metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
        (artifacts / "CHECKSUMS.sha256").write_text("".join(
            f"{digest(p)}  {p.name}\n" for p in sorted(artifacts.iterdir()) if p.is_file()))
        subprocess.run([os.sys.executable, str(ROOT / "scripts/validate-release.py"), str(artifacts)], check=True)
        output.mkdir(parents=True, exist_ok=True)
        for artifact in sorted(artifacts.iterdir()):
            shutil.copy2(artifact, output / artifact.name)
        print(f"Verified release artifacts: {output}")


if __name__ == "__main__":
    main()
