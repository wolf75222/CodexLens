#!/usr/bin/env python3
"""Embed, sign and validate the pinned native macOS updater framework."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess

SPARKLE_VERSION = "2.10.0"
FRAMEWORK_LOAD_PATH = "@rpath/Sparkle.framework/Versions/B/Sparkle"
EMBEDDED_RPATHS = {"@executable_path/../Frameworks", "@loader_path/../Frameworks"}
FRAMEWORK_LINKS = {
    "Versions/Current": "B",
    "Sparkle": "Versions/Current/Sparkle",
    "Resources": "Versions/Current/Resources",
    "Autoupdate": "Versions/Current/Autoupdate",
    "Updater.app": "Versions/Current/Updater.app",
    "XPCServices": "Versions/Current/XPCServices",
}
NESTED_BUNDLES = {
    "Versions/B/Updater.app": "Updater",
    "Versions/B/XPCServices/Installer.xpc": "Installer",
    "Versions/B/XPCServices/Downloader.xpc": "Downloader",
}


def run(args: list[str]) -> str:
    result = subprocess.run(args, check=True, capture_output=True, text=True)
    return result.stdout


def version(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", value):
        raise ValueError("Invalid minimum macOS version.")
    return tuple(int(piece) for piece in value.split(".")) + (0,) * (3 - len(value.split(".")))


def minimum_os(info: dict, target: str) -> None:
    if version(info.get("LSMinimumSystemVersion", "")) > version(target):
        raise ValueError("Sparkle component requires a newer macOS than the application.")


def framework_structure(framework: Path, target: str) -> list[Path]:
    if framework.is_symlink() or not framework.is_dir():
        raise ValueError("Expected an embedded Sparkle framework directory.")
    for relative, expected in FRAMEWORK_LINKS.items():
        link = framework / relative
        if not link.is_symlink() or os.readlink(link) != expected:
            raise ValueError("Sparkle framework symlink layout is incorrect: " + relative)
    root = framework.resolve()
    for item in framework.rglob("*"):
        if item.is_symlink() and (not item.exists() or not item.resolve().is_relative_to(root)):
            raise ValueError("Sparkle framework contains an external or broken link.")
    info = plistlib.loads((framework / "Resources/Info.plist").read_bytes())
    if info.get("CFBundleShortVersionString") != SPARKLE_VERSION or info.get("CFBundleIdentifier") != "org.sparkle-project.Sparkle":
        raise ValueError("Sparkle framework does not match the pinned dependency.")
    minimum_os(info, target)
    binaries = [framework / "Versions/B/Sparkle", framework / "Versions/B/Autoupdate"]
    for relative, name in NESTED_BUNDLES.items():
        bundle = framework / relative
        nested_info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        if nested_info.get("CFBundleExecutable") != name or nested_info.get("CFBundleShortVersionString") != SPARKLE_VERSION:
            raise ValueError("Unexpected Sparkle helper bundle.")
        minimum_os(nested_info, target)
        binaries.append(bundle / "Contents/MacOS" / name)
    if any(not item.is_file() or not os.access(item, os.X_OK) for item in binaries):
        raise ValueError("Sparkle helper executable is missing or is not executable.")
    return binaries


def find_framework(artifacts: Path, architecture: str, target: str) -> Path:
    matches = []
    for xcframework in artifacts.rglob("Sparkle.xcframework"):
        info = plistlib.loads((xcframework / "Info.plist").read_bytes())
        for library in info.get("AvailableLibraries", []):
            if library.get("SupportedPlatform") != "macos" or library.get("SupportedPlatformVariant"):
                continue
            if architecture not in library.get("SupportedArchitectures", []):
                continue
            identifier, relative = library.get("LibraryIdentifier", ""), library.get("LibraryPath", "")
            if not identifier or Path(identifier).name != identifier or relative != "Sparkle.framework":
                raise ValueError("Unsafe Sparkle binary artifact path.")
            framework = xcframework / identifier / relative
            if not framework.resolve().is_relative_to(xcframework.resolve()):
                raise ValueError("Sparkle artifact escapes its XCFramework.")
            framework_structure(framework, target)
            matches.append(framework)
    if len(matches) != 1:
        raise ValueError("Expected exactly one compatible pinned Sparkle binary artifact.")
    return matches[0]


def embed(artifacts: Path, app: Path) -> None:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    architectures = run(["lipo", "-archs", str(binary)]).split()
    if architectures != ["arm64"]:
        raise ValueError("The production updater channel currently requires arm64.")
    framework = find_framework(artifacts, "arm64", info["LSMinimumSystemVersion"])
    license_file = framework.parent.parent.parent / "LICENSE"
    if not license_file.is_file():
        raise ValueError("Sparkle distribution license is missing.")
    destination = app / "Contents/Frameworks/Sparkle.framework"
    if destination.is_symlink():
        raise ValueError("Refusing to replace a linked embedded framework.")
    if destination.exists():
        shutil.rmtree(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    # ditto preserves the versioned framework's symlinks and executable modes.
    run(["ditto", str(framework), str(destination)])
    # A checkout in iCloud Drive can attach Finder/file-provider metadata to
    # the source artifact. Remove it only from this owned copied framework.
    run(["xattr", "-cr", str(destination)])
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(license_file, resources / "Sparkle-LICENSE.txt")
    framework_structure(destination, info["LSMinimumSystemVersion"])


def signing_commands(app: Path, identity: str) -> list[list[str]]:
    framework = app / "Contents/Frameworks/Sparkle.framework"
    common = ["codesign", "--force", "--sign", identity]
    if identity != "-":
        common += ["--options", "runtime", "--timestamp"]
    nested = [
        ("Versions/B/XPCServices/Installer.xpc", []),
        ("Versions/B/XPCServices/Downloader.xpc", ["--preserve-metadata=entitlements"]),
        ("Versions/B/Autoupdate", []),
        ("Versions/B/Updater.app", []),
    ]
    # Sign inside-out, never --deep sign: only Downloader keeps its specific
    # entitlements, following Sparkle's manual distribution signing contract.
    commands = [common + [str(library)] for library in sorted((app / "Contents/Frameworks").glob("libswift*.dylib"))]
    commands += [common + options + [str(framework / relative)] for relative, options in nested]
    commands.append(common + [str(framework)])
    commands.append(common + ["--identifier", "fr.codexlens.inspector", str(app)])
    commands.append(["codesign", "--verify", "--deep", "--strict", str(app)])
    return commands


def sign(app: Path, identity: str) -> None:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    framework_structure(app / "Contents/Frameworks/Sparkle.framework", info["LSMinimumSystemVersion"])
    for command in signing_commands(app, identity):
        run(command)


def linkage_dependencies(output: str) -> list[str]:
    return [line.strip().split(" (", 1)[0] for line in output.splitlines() if line.startswith("\t")]


def runtime_search_paths(output: str) -> list[str]:
    return re.findall(r"\bcmd LC_RPATH\s+cmdsize \d+\s+path (.*?) \(offset", output)


def toolchain_swift_path(path: str, tool: Path) -> bool:
    """Recognize only existing Swift macOS directories in the active toolchain."""
    candidate = Path(path)
    if not candidate.is_absolute() or not candidate.is_dir():
        return False
    try:
        relative = candidate.resolve().relative_to((tool.resolve().parent.parent / "lib").resolve())
    except ValueError:
        return False
    return (len(relative.parts) == 2 and relative.parts[1] == "macosx"
            and re.fullmatch(r"swift(?:-\d+(?:\.\d+)*)?", relative.parts[0]) is not None)


def prepare_runtime(app: Path) -> None:
    """Copy required Swift libraries before removing verified toolchain rpaths.

    SwiftPM adds an absolute compiler compatibility-library fallback even when
    the program does not load that library. Use Apple's dependency scanner
    first, then keep the packaged executable independent of that build Mac.
    Unknown external search paths are left intact and fail release validation.
    """
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    binary = app / "Contents/MacOS" / info["CFBundleExecutable"]
    frameworks = app / "Contents/Frameworks"
    component_binaries = framework_structure(frameworks / "Sparkle.framework", info["LSMinimumSystemVersion"])
    tool = Path(run(["xcrun", "--find", "swift-stdlib-tool"]).strip())
    rpaths = runtime_search_paths(run(["otool", "-l", str(binary)]))
    removable = sorted({path for path in rpaths if toolchain_swift_path(path, tool)})
    for library in frameworks.glob("libswift*.dylib"):
        if library.is_symlink() or not library.is_file():
            raise ValueError("Refusing a linked or invalid embedded Swift library.")
        library.unlink()
    scanning = ["xcrun", "swift-stdlib-tool", "--copy", "--platform", "macosx",
                "--scan-executable", str(binary), "--scan-folder", str(frameworks),
                "--destination", str(frameworks)]
    run(scanning)
    # New compatibility libraries may live in a versioned Swift directory,
    # rather than the tool's default usr/lib/swift/macosx directory.
    for path in removable:
        run(scanning + ["--source-libraries", path])
    copied = {library.name for library in frameworks.glob("libswift*.dylib") if library.is_file() and not library.is_symlink()}
    compatibility_sources: dict[str, list[Path]] = {}
    for path in removable:
        for library in Path(path).glob("libswift*.dylib"):
            compatibility_sources.setdefault(library.name, []).append(library)
    required = set()
    for executable in [binary] + component_binaries:
        for dependency in linkage_dependencies(run(["otool", "-L", str(executable)])):
            if dependency.startswith("@rpath/libswift"):
                name = dependency.removeprefix("@rpath/")
                if not re.fullmatch(r"libswift[A-Za-z0-9_]*\.dylib", name):
                    raise ValueError("Unexpected Swift compatibility library load path.")
                required.add(name)
            elif dependency.startswith("/usr/lib/swift/") and Path(dependency).name in compatibility_sources:
                # Apple compatibility libraries use /usr/lib/swift install
                # names while older systems resolve the bundled fallback.
                required.add(Path(dependency).name)
    for name in sorted(required - copied):
        sources = compatibility_sources.get(name, [])
        if len(sources) == 1:
            # The standalone Apple scanner can classify /usr/lib/swift names
            # as system-provided, even for a newer compatibility library. Its
            # resource option copies that specific required library and its
            # dependencies without signing; the inside-out signer follows.
            run(scanning + ["--source-libraries", str(sources[0].parent),
                            "--resource-library", name, "--resource-destination", str(frameworks)])
        elif len(sources) > 1:
            raise ValueError("Ambiguous active-toolchain Swift compatibility library.")
    copied = {library.name for library in frameworks.glob("libswift*.dylib") if library.is_file() and not library.is_symlink()}
    if not required.issubset(copied):
        raise ValueError("Required Swift compatibility libraries were not embedded; preserving toolchain search paths.")
    for path in removable:
        run(["install_name_tool", "-delete_rpath", path, str(binary)])
    resources = app / "Contents/Resources"
    resources.mkdir(parents=True, exist_ok=True)
    (resources / "RuntimeLibraries.json").write_text(json.dumps({"schemaVersion": 1,
        "scanner": "xcrun swift-stdlib-tool", "required": sorted(required), "embedded": sorted(copied),
        "removedToolchainSearchPathCount": len(removable)}, indent=2) + "\n")


def validate_linkage(binary: Path, minimum: str, *, application: bool = False) -> None:
    dependencies = linkage_dependencies(run(["otool", "-L", str(binary)]))
    if any(path.startswith("/") and not path.startswith(("/System/Library/", "/usr/lib/")) for path in dependencies):
        raise ValueError("Executable references a library outside its bundle or system frameworks.")
    commands = run(["otool", "-l", str(binary)])
    rpaths = runtime_search_paths(commands)
    if any(path.startswith("/") and not path.startswith(("/System/Library/", "/usr/lib/")) for path in rpaths):
        raise ValueError("Executable contains an external library search path.")
    if application and (FRAMEWORK_LOAD_PATH not in dependencies or not EMBEDDED_RPATHS.intersection(rpaths)):
        raise ValueError("Application does not resolve Sparkle from its embedded Frameworks directory.")
    build = run(["xcrun", "vtool", "-show-build", str(binary)])
    # Swift compatibility libraries can also contain Catalyst load commands;
    # qualify the macOS platform, including older x86_64 minimum-OS commands.
    minimums = re.findall(r"\bplatform MACOS\s+minos (\d+(?:\.\d+){0,2})", build)
    minimums += re.findall(r"\bcmd LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+){0,2})", build)
    if not minimums or any(version(value) > version(minimum) for value in minimums):
        raise ValueError("Executable deployment target is incompatible with the application.")


def validate_embedded(app: Path) -> None:
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    minimum = info["LSMinimumSystemVersion"]
    framework = app / "Contents/Frameworks/Sparkle.framework"
    for binary in framework_structure(framework, minimum):
        validate_linkage(binary, minimum)
    for library in sorted((app / "Contents/Frameworks").glob("libswift*.dylib")):
        if library.is_symlink() or not library.is_file():
            raise ValueError("Invalid embedded Swift runtime library.")
        validate_linkage(library, minimum)
    validate_linkage(app / "Contents/MacOS" / info["CFBundleExecutable"], minimum, application=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    copy = actions.add_parser("embed")
    copy.add_argument("--artifacts", type=Path, required=True)
    copy.add_argument("--app", type=Path, required=True)
    signing = actions.add_parser("sign")
    signing.add_argument("--app", type=Path, required=True)
    signing.add_argument("--identity", default=os.environ.get("LENS_SIGNING_IDENTITY", "-"))
    runtime = actions.add_parser("runtime")
    runtime.add_argument("--app", type=Path, required=True)
    validation = actions.add_parser("validate")
    validation.add_argument("--app", type=Path, required=True)
    args = parser.parse_args()
    if args.action == "embed":
        embed(args.artifacts, args.app)
    elif args.action == "sign":
        sign(args.app, args.identity)
    elif args.action == "runtime":
        prepare_runtime(args.app)
    else:
        validate_embedded(args.app)


if __name__ == "__main__":
    main()
