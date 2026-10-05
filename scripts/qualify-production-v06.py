#!/usr/bin/env python3
"""Prepare/run a QA copy of the real @main app, without rebuilding its executable.

Run only after the source/build freeze. This is a software diagnostic launcher,
not GUI automation: it neither injects input nor captures another application's UI.
"""
import argparse
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import struct
import subprocess
import tempfile
import time

SANDBOX = "(version 1)(allow default)(deny network*)"


def running_qa_apps(process_output=None):
    """Identify test copies only; production windows never block a QA launch."""
    if process_output is None:
        inspected = command(["/bin/ps", "-axo", "pid=,comm="])
        if inspected["status"] != 0:
            raise SystemExit("Cannot inspect running apps; refusing another QA launch.")
        process_output = inspected["stdout"]
    result = []
    for line in process_output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or not fields[0].isdigit():
            continue
        executable = Path(fields[1])
        if executable.name != "CodexLens" or executable.parent.name != "MacOS":
            continue
        app = executable.parent.parent.parent
        # A deleted test bundle can still have a live process. Keep recognizing
        # our old/new test names even when its Info.plist is no longer present.
        is_qa = app.name in ("Codex Lens QA.app", "Codex Lens (test).app")
        try:
            info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
            is_qa |= str(info.get("CFBundleIdentifier", "")).startswith("fr.codexlens.qa.")
        except (OSError, ValueError):
            pass
        if is_qa:
            result.append({"pid": int(fields[0]), "app": str(app)})
    return result


@contextmanager
def exclusive_qa_launch(lock_path=None):
    """Serialize launches and refuse to add another test app to the Dock."""
    path = lock_path or Path(tempfile.gettempdir()) / ("codex-lens-qa-launch-%s.lock" % os.getuid())
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "a") as lock:
        if os.fstat(lock.fileno()).st_uid != os.getuid():
            raise SystemExit("QA launch lock belongs to another user.")
        try:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Another QA launch is in progress; wait for it to finish.")
        active = running_qa_apps()
        if active:
            details = "; ".join("PID %s: %s" % (a["pid"], a["app"]) for a in active)
            raise SystemExit("A Lens test copy is already open. Quit it or use --stop with its recorded --output before launching another. " + details)
        yield


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def resident(path):
    if getattr(path.stat(), "st_flags", 0) & 0x40000000:
        raise SystemExit("Refusing SF_DATALESS input: " + str(path))


def command(args):
    result = subprocess.run(args, capture_output=True, text=True, check=False)
    return {"command": args, "status": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr}


def write(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def macho_sections(path):
    """Hash every file-backed section of our thin arm64 Mach-O (not its signature)."""
    data = path.read_bytes()
    if len(data) < 32 or struct.unpack_from("<I", data)[0] != 0xFEEDFACF:
        raise SystemExit("Expected a thin little-endian Mach-O 64 executable.")
    header = struct.unpack_from("<8I", data)
    if header[1] != 0x0100000C:
        raise SystemExit("This QA section verifier supports the delivered arm64 binary only.")
    cursor = 32
    sections = []
    for _ in range(header[4]):
        if cursor + 8 > len(data): raise SystemExit("Malformed Mach-O load commands")
        kind, length = struct.unpack_from("<2I", data, cursor)
        if length < 8 or cursor + length > len(data): raise SystemExit("Malformed Mach-O command length")
        if kind == 0x19:  # LC_SEGMENT_64
            if length < 72: raise SystemExit("Malformed segment command")
            segment = struct.unpack_from("<II16sQQQQIIII", data, cursor)
            count = segment[9]
            if 72 + 80 * count > length: raise SystemExit("Malformed section table")
            for index in range(count):
                values = struct.unpack_from("<16s16sQQ8I", data, cursor + 72 + 80 * index)
                section_name = values[0].split(b"\0", 1)[0].decode("ascii")
                segment_name = values[1].split(b"\0", 1)[0].decode("ascii")
                address, size, offset, alignment = values[2:6]
                flags = values[8]
                zero_filled = flags & 0xFF in (1, 0xC, 0x12)
                if not zero_filled and offset + size > len(data): raise SystemExit("Section exceeds file")
                section_data = b"" if zero_filled else data[offset:offset + size]
                sections.append({"segment": segment_name, "section": section_name,
                                 "address": address, "virtualBytes": size, "fileOffset": offset,
                                 "alignment": alignment, "flags": flags, "zeroFilled": zero_filled,
                                 "fileBackedBytes": len(section_data),
                                 "sha256": hashlib.sha256(section_data).hexdigest()})
        cursor += length
    if not any(s["segment"] == "__TEXT" and s["section"] == "__text" for s in sections):
        raise SystemExit("No instruction section found")
    return sections


def require_private_new(path):
    if not path.is_absolute() or not str(path).startswith(("/private/tmp/", "/tmp/")):
        raise SystemExit("Use a new absolute /private/tmp or /tmp output directory.")
    if path.exists():
        raise SystemExit("Refusing to replace an existing qualification directory.")


def stop(out):
    receipt = json.loads((out / "production-startup-receipt.json").read_text())
    pid = receipt["pid"]
    expected = receipt["executable"]
    inspected = command(["/bin/ps", "-p", str(pid), "-o", "command="])
    # Exact prefix because ps includes arguments. Never kill a guessed PID/name.
    actual = inspected["stdout"].strip()
    if inspected["status"] == 0 and (actual == expected or actual.startswith(expected + " ")):
        os.kill(pid, 15)
        write(out / "production-stop-receipt.json",
              {"pid": pid, "identityVerified": True, "method": "SIGTERM-own-QA-app",
               "processCommand": actual, "nativeQuitQualified": False})
    elif inspected["status"] != 0:
        write(out / "production-stop-receipt.json",
              {"pid": pid, "alreadyExited": True, "nativeQuitQualified": False})
    else:
        raise SystemExit("PID identity changed; refusing to stop it.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--production-app", type=Path)
    parser.add_argument("--source-root", type=Path)
    parser.add_argument("--build-source-manifest", type=Path,
                        help="Source manifest supplied by the production build owner (required).")
    parser.add_argument("--expected-uuid", help="Production build UUID supplied by the build owner (required).")
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--appearance", choices=["light", "dark"], default="light")
    parser.add_argument("--mutable-appearance", action="store_true", help="Seed ONLY the unique QA preferences domain, instead of forcing NSArgumentDomain; permits real theme changes in Settings.")
    parser.add_argument("--run", action="store_true", help="Launch real app; leave it open for authorized CUA inspection.")
    parser.add_argument("--seed-investigations", type=Path, help="Own anonymous archive generated by the native chat fixture probe; no credentials or inference.")
    parser.add_argument("--no-session", action="store_true", help="Test first launch without preloading a session; uses the same exclusive launch guard.")
    parser.add_argument("--resign-qa", action="store_true",
                        help="Explicitly ad-hoc sign ONLY the new QA copy; verify every Mach-O section unchanged. The executable file hash changes.")
    parser.add_argument("--gui-relaunch-environment", action="store_true",
                        help="Persist ONLY the anonymous QA paths in its Info.plist LSEnvironment, so Launch Services relaunches keep the fixture scope. GUI relaunches do not inherit sandbox-exec's network denial.")
    parser.add_argument("--stop", action="store_true", help="Stop only the PID/executable recorded by this script.")
    args = parser.parse_args()
    if args.stop:
        stop(args.output)
        return
    if not args.production_app or not args.source_root or not args.corpus or not args.build_source_manifest or not args.expected_uuid:
        parser.error("--production-app, --source-root, --corpus, --build-source-manifest and --expected-uuid are required for preparation")
    for path in (args.production_app, args.source_root, args.corpus, args.build_source_manifest):
        if not path.is_absolute():
            parser.error("Input paths must be absolute")
    require_private_new(args.output)
    corpus_path = args.corpus / "corpus-manifest.json"
    resident(corpus_path)
    corpus = json.loads(corpus_path.read_text())
    if not (args.corpus / "ANONYMOUS_FIXTURE").is_file() or not corpus.get("anonymous"):
        raise SystemExit("Expected the generated anonymous fixture marker/manifest.")
    info_path = args.production_app / "Contents/Info.plist"
    resident(info_path)
    original = plistlib.loads(info_path.read_bytes())
    exe_name = original.get("CFBundleExecutable")
    if not isinstance(exe_name, str) or "/" in exe_name:
        raise SystemExit("Invalid CFBundleExecutable")
    executable = args.production_app / "Contents/MacOS" / exe_name
    resident(executable)
    exe_hash = digest(executable)
    uuid = command(["/usr/bin/xcrun", "dwarfdump", "--uuid", str(executable)])
    if uuid["status"] != 0 or args.expected_uuid.upper() not in uuid["stdout"].upper():
        raise SystemExit("Executable UUID does not match the supplied production build identity.")
    resident(args.build_source_manifest)
    built_sources = json.loads(args.build_source_manifest.read_text())
    sources = {}
    for path in sorted((args.source_root / "Sources").rglob("*")):
        if path.is_file() and path.suffix in (".swift", ".h", ".modulemap"):
            resident(path)
            sources[str(path.relative_to(args.source_root))] = {"sha256": digest(path), "bytes": path.stat().st_size}
    for name, value in sources.items():
        if built_sources.get(name, {}).get("sha256") != value["sha256"]:
            raise SystemExit("Source does not match the supplied production build manifest: " + name)
    # Require the explicitly implemented injection points; never change HOME.
    store_source = args.source_root / "Sources/CodexLens/LensStore.swift"
    resident(store_source)
    store_text = store_source.read_text()
    location_source = args.source_root / "Sources/LensCore/CodexSourceLocation.swift"
    if "CodexSourceLocation.observationHome()" in store_text:
        resident(location_source)
        if "LENS_CODEX_HOME" not in location_source.read_text():
            raise SystemExit("Source resolver no longer honors the QA observation override.")
    elif "LENS_CODEX_HOME" not in store_text:
        raise SystemExit("App injection point missing from frozen source: LENS_CODEX_HOME")
    for key in ("LENS_CACHE_DIRECTORY", "LENS_ARCHIVE_DIRECTORY"):
        if key not in store_text:
            raise SystemExit("App injection point missing from frozen source: " + key)
    args.output.mkdir(parents=True)
    qa_app = args.output / "Codex Lens (test).app"
    for path in args.production_app.rglob("*"):
        if path.is_file(): resident(path)
    shutil.copytree(args.production_app, qa_app, symlinks=True)
    qa_info = dict(original)
    if args.gui_relaunch_environment:
        qa_info["LSEnvironment"] = {
            "LENS_CODEX_HOME": corpus["home"],
            "LENS_CACHE_DIRECTORY": str(args.output / "runtime/cache"),
            "LENS_ARCHIVE_DIRECTORY": str(args.output / "runtime/archive"),
        }
    suffix = hashlib.sha256(str(args.output).encode()).hexdigest()[:12]
    qa_info["CFBundleIdentifier"] = "fr.codexlens.qa.v06." + suffix
    qa_info["CFBundleName"] = "Codex Lens (test)"
    qa_info["CFBundleDisplayName"] = "Codex Lens (test)"
    # Do not register a second handler for production deep links.
    qa_info.pop("CFBundleURLTypes", None)
    (qa_app / "Contents/Info.plist").write_bytes(plistlib.dumps(qa_info, sort_keys=True))
    qa_executable = qa_app / "Contents/MacOS" / exe_name
    if digest(qa_executable) != exe_hash:
        raise SystemExit("Executable changed while preparing the QA copy")
    original_sections = macho_sections(executable)
    signing = None
    if args.resign_qa:
        signing = command(["/usr/bin/codesign", "--force", "--sign", "-", "--identifier", qa_info["CFBundleIdentifier"], str(qa_app)])
        attempts = [signing]
        # One retry of the exact same ad-hoc signing command for this local
        # subsystem error. Keep the failed attempt; all identity/section/signature
        # verification below still applies. Never retry other signing failures.
        if signing["status"] != 0 and "internal error in Code Signing subsystem" in signing["stderr"]:
            signing = command(signing["command"])
            attempts.append(signing)
        write(args.output / "qa-signing-attempts.json", attempts)
        if signing["status"] != 0:
            write(args.output / "qa-signing-failure.json", signing)
            raise SystemExit("QA re-signing failed; production app was not changed")
    qa_sections = macho_sections(qa_executable)
    if qa_sections != original_sections:
        write(args.output / "qa-section-mismatch.json", {"before": original_sections, "after": qa_sections})
        raise SystemExit("QA re-signing changed a Mach-O section; refusing to launch")
    qa_hash = digest(qa_executable)
    qa_uuid = command(["/usr/bin/xcrun", "dwarfdump", "--uuid", str(qa_executable)])
    if args.expected_uuid.upper() not in qa_uuid["stdout"].upper():
        raise SystemExit("QA executable UUID changed; refusing to launch")
    for name, value in sources.items():
        if digest(args.source_root / name) != value["sha256"]:
            raise SystemExit("Sources changed while copying; wait for a new freeze")
    delta = {key: {"before": original.get(key), "after": qa_info.get(key)}
             for key in sorted(set(original) | set(qa_info))
             if original.get(key) != qa_info.get(key)}
    runtime = args.output / "runtime"
    for name in ("cache", "archive"):
        (runtime / name).mkdir(parents=True)
    if args.seed_investigations:
        seed = args.seed_investigations.resolve()
        if not str(seed).startswith('/private/tmp/') or not (seed.parent/'ANONYMOUS_CHAT_FIXTURE').is_file():
            raise SystemExit('Expected the native anonymous chat fixture marker in private tmp.')
        for file in seed.iterdir():
            if file.is_symlink() or not file.is_file() or file.suffix != '.json':
                raise SystemExit('Non-regular anonymous archive input refused.')
            resident(file)
            record = json.loads(file.read_text())
            if (record.get('capsule', {}).get('rootThreadID') != corpus['rootID'] or
                not record.get('excludedFromAutocollection') or record.get('analysisIsSourceEvidence') or
                record.get('codexChatID') != '66666666-6666-4666-8666-666666666666'):
                raise SystemExit('Chat fixture scope mismatch.')
            shutil.copy2(file, runtime/'archive'/file.name)
    environment = {"LENS_CODEX_HOME": corpus["home"],
                   "LENS_CACHE_DIRECTORY": str(runtime / "cache"),
                   "LENS_ARCHIVE_DIRECTORY": str(runtime / "archive")}
    preference_seed = None
    argv = ["/usr/bin/sandbox-exec", "-p", SANDBOX, str(qa_executable)]
    if not args.no_session:
        argv += ["--session", corpus["rootID"]]
    if args.mutable_appearance:
        domain = qa_info["CFBundleIdentifier"]
        if not domain.startswith("fr.codexlens.qa.v06."):
            raise SystemExit("Refusing to seed a non-QA preferences domain")
        preference_seed = command(["/usr/bin/defaults", "write", domain, "lensAppearance", "-string", args.appearance])
        if preference_seed["status"] != 0:
            raise SystemExit("Cannot seed the own QA appearance preference")
    else:
        argv += ["-lensAppearance", args.appearance]
    write(args.output / "production-qa-manifest.json", {
        "schemaVersion": 1, "preparedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "productionApp": str(args.production_app), "qaApp": str(qa_app),
        "productionEntryPointPreserved": True, "executableByteIdentical": qa_hash == exe_hash,
        "productionExecutableSHA256": exe_hash, "executableSHA256": qa_hash, "executableUUID": qa_uuid,
        "expectedBuildUUID": args.expected_uuid.upper(),
        "buildSourceManifest": str(args.build_source_manifest), "buildSourceManifestSHA256": digest(args.build_source_manifest),
        "allSourceInputsMatchSuppliedBuildManifest": True,
        "sourceRoot": str(args.source_root), "sources": sources,
        "infoPlistDelta": delta, "originalInfoSHA256": digest(info_path),
        "qaInfoSHA256": digest(qa_app / "Contents/Info.plist"),
        "productionSignature": command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(args.production_app)]),
        "qaSignature": command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(qa_app)]),
        "qaNotResigned": not args.resign_qa, "qaSigningCommand": signing,
        "qaSignatureLimit": ("Explicit QA-only ad-hoc re-signature changes the executable file/signature hash. All Mach-O sections and the UUID are verified unchanged; this is not byte-identical to production and not the distributable app." if args.resign_qa else "Info-only QA modification can invalidate the bundle resource signature; the executable is not resigned or modified. This QA bundle is not the distributable app."),
        "machOSectionProof": {"allSectionsIdentical": True, "sectionCount": len(original_sections), "before": original_sections, "after": qa_sections,
                              "scope": "Every file-backed section including instructions, Swift metadata and constants; zero-filled sections metadata. Load-command/signature blobs are not claimed identical after signing."},
        "corpusManifest": str(corpus_path), "corpusManifestSHA256": digest(corpus_path),
        "anonymousInvestigationSeed": str(args.seed_investigations) if args.seed_investigations else None,
        "environmentOverrides": environment, "preferencesDomain": qa_info["CFBundleIdentifier"],
        "appearanceOverrideScope": "Unique QA UserDefaults domain; mutable from Settings" if args.mutable_appearance else "Foundation NSArgumentDomain (-lensAppearance)",
        "appearancePreferenceSeed": preference_seed,
        "guiRelaunchEnvironmentPersisted": args.gui_relaunch_environment,
        "guiRelaunchNetworkDeniedByOS": False,
        "guiRelaunchLimit": "LSEnvironment preserves anonymous paths for Launch Services only. A GUI launch does not inherit sandbox-exec; network denial applies only to the recorded direct-launch command.",
        "command": argv, "networkDeniedByOS": True,
        "exclusiveTestAppLaunch": True, "firstRunWithoutPreloadedSession": args.no_session,
        "HOMEOrCFFIXEDOverride": False, "authFilesRead": False,
        "startupIsNotInteractionQualification": True})
    if not args.run:
        print("QA_PREPARED", str(qa_app), "(no launch)")
        return
    with exclusive_qa_launch():
        launch_env = os.environ.copy()
        launch_env.update(environment)
        # Never forward credential values to the diagnostic app. Do not inspect them.
        for name in ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_AUTH_TOKEN"):
            launch_env.pop(name, None)
        with (args.output / "production-runtime.log").open("wb") as log:
            child = subprocess.Popen(argv, env=launch_env, stdout=log, stderr=subprocess.STDOUT,
                                     start_new_session=True)
            time.sleep(5)
            status = child.poll()
        inspected = command(["/bin/ps", "-p", str(child.pid), "-o", "command="])
        write(args.output / "production-startup-receipt.json", {
            "pid": child.pid, "executable": str(qa_executable), "aliveAfterSeconds": 5,
            "alive": status is None, "exitStatus": status, "processCommand": inspected,
            "productionEntryPointPreserved": True, "windowOrFocusQualified": False,
            "GUIInputInjected": False, "screenshotsCaptured": False, "networkDeniedByOS": True,
            "preferencesDomain": qa_info["CFBundleIdentifier"], "environmentOverrides": environment,
            "shutdown": "left-open-own-QA-app" if status is None else "exited"})
        if status is not None:
            raise SystemExit("QA application exited during startup; inspect production-runtime.log")
        print("QA_STARTED", child.pid, str(qa_app))


if __name__ == "__main__":
    main()
