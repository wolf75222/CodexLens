#!/usr/bin/env python3
"""Replay catalog performance on anonymous fixtures using existing Release objects."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sqlite3
import statistics
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parents[1]
HARNESS = ROOT / "Tests/NativeUI/SessionCatalogPerformanceMain.swift"
SOURCE_ASSUMPTION = (
    "The existing Release module and objects are assumed to belong together and "
    "correspond to the captured sources. File hashes and mtimes identify the inputs. "
    "Copying current sources does not establish which sources produced those objects; "
    "later source edits do not update the frozen binary inputs. Rebuild explicitly first."
)


def sha256(path):
    if getattr(path.stat(), "st_flags", 0) & 0x40000000:
        raise ValueError(f"Nonresident file refused; this replay does not fetch cloud sources: {path}")
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def capture(arguments):
    result = subprocess.run(arguments, cwd=ROOT, text=True, capture_output=True, timeout=30)
    return {"command": arguments, "exit_code": result.returncode,
            "stdout": result.stdout.strip(), "stderr": result.stderr.strip()}


def bounded_integer(minimum, maximum):
    def convert(value):
        number = int(value)
        if not minimum <= number <= maximum:
            raise argparse.ArgumentTypeError(f"must be between {minimum} and {maximum}")
        return number
    return convert


def arguments():
    parser = argparse.ArgumentParser(
        description="Measure SessionEngine.catalog on a newly generated anonymous fixture. "
                    "No observed Codex home, network, or implicit rebuild.",
        epilog="Build first if needed: bash scripts/build.sh --profile\n"
               "Default: python3 scripts/measure-session-catalog.py --output /private/tmp/lens-catalog-500\n"
               "Stress: add --sessions 5000 --padding-bytes 131072\n"
               "The output must be new and under /private/tmp. Existing paths are never purged.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True, help="new absolute private output under /private/tmp")
    parser.add_argument("--sessions", type=bounded_integer(1, 5000), default=500, help="session count, 1..5000 (default: 500)")
    parser.add_argument("--padding-bytes", type=bounded_integer(0, 131072), default=22528,
                        help="first-record anonymous padding, 0..131072 (default: 22528)")
    return parser.parse_args()


def new_output(requested):
    if not requested.is_absolute() or requested.name in ("", ".", ".."):
        raise ValueError("--output must name a new absolute directory under /private/tmp")
    parent = requested.parent.resolve(strict=True)
    private_tmp = Path("/private/tmp").resolve(strict=True)
    if parent != private_tmp and private_tmp not in parent.parents:
        raise ValueError("--output must be under /private/tmp; no user home is accepted")
    output = parent / requested.name
    if os.path.lexists(output):
        raise ValueError("--output already exists; choose a new path (nothing was purged)")
    output.mkdir(mode=0o700)
    return output


def release_directory():
    preferred = ROOT / ".build/release"
    candidates = [preferred] if preferred.exists() else sorted((ROOT / ".build").glob("*/release"))
    available = [path.resolve() for path in candidates
                 if (path / "Modules/LensCore.swiftmodule").is_file()
                 and list((path / "LensCore.build").glob("*.swift.o"))]
    available = list(dict.fromkeys(available))
    if len(available) != 1:
        raise ValueError("Expected one existing Release LensCore module/object set. "
                         "Run bash scripts/build.sh --profile first; this tool never rebuilds the repository.")
    return available[0]


def freeze(output, release):
    sources = {"head": capture(["git", "rev-parse", "HEAD"]),
               "branch": capture(["git", "branch", "--show-current"]),
               "dirty_state": capture(["git", "status", "--porcelain"]),
               "worktrees": capture(["git", "worktree", "list"])}
    entries, origins = {}, []

    def copy(source, target):
        stat = source.stat()
        if getattr(stat, "st_flags", 0) & 0x40000000:
            raise ValueError(f"Nonresident source refused; use a resident checkout/build: {source}")
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        digest = sha256(target)
        entries[str(target.relative_to(output))] = {
            "origin": str(source), "sha256": digest, "bytes": stat.st_size, "origin_mtime_ns": stat.st_mtime_ns}
        origins.append((source, digest))

    for path in sorted((release / "Modules").glob("LensCore.*")):
        if path.is_file(): copy(path, output / "frozen/Modules" / path.name)
    for path in sorted((release / "LensCore.build").glob("*.swift.o")):
        copy(path, output / "frozen/LensCore.build" / path.name)
    for directory in ["LensCore", "CSQLite"]:
        for path in sorted((ROOT / "Sources" / directory).rglob("*")):
            if path.is_file() and path.suffix in [".swift", ".h", ".modulemap"]:
                copy(path, output / "frozen/Sources" / directory / path.relative_to(ROOT / "Sources" / directory))
    copy(HARNESS, output / HARNESS.name)
    copy(Path(__file__).resolve(), output / "measure-session-catalog.py")
    for path, digest in origins:
        if sha256(path) != digest:
            raise ValueError(f"Input changed while freezing: {path}; wait for builds/edits to finish")
    manifest = {"repository": str(ROOT), "release_directory": str(release),
                "source_identity": sources, "source_freeze_assumption": SOURCE_ASSUMPTION,
                "frozen_inputs_stable_during_copy": True, "files": entries}
    write_json(output / "source-manifest.json", manifest)
    return manifest


def generate_fixture(output, count, padding):
    home = output / "fixture"
    home.mkdir(mode=0o700)
    (output / "registry").mkdir(mode=0o700)
    (output / "caches").mkdir(mode=0o700)
    files, titles, sizes = {}, [], []
    relations = {"root": 0, "subagent": 0, "fork": 0, "continuation": 0}

    def identity(index): return f"00000000-0000-4000-8000-{index + 1:012d}"

    def record(path):
        files[str(path.relative_to(home))] = {"sha256": sha256(path), "bytes": path.stat().st_size}

    database = sqlite3.connect(home / "state_5.sqlite")
    try:
        database.execute("CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT, updated_at INTEGER, updated_at_ms INTEGER, cwd TEXT, title TEXT, cli_version TEXT, agent_nickname TEXT, agent_path TEXT, source TEXT, git_branch TEXT, git_sha TEXT)")
        database.execute("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)")
        for index in range(count):
            owner, parent = identity(index), identity(index // 10 * 10)
            relation = {1: "subagent", 2: "fork", 3: "continuation"}.get(index % 10, "root")
            relations[relation] += 1
            path = home / ("archived_sessions" if index % 5 == 0 else "sessions") / f"2026/09/{index % 28 + 1:02d}" / f"rollout-2026-09-{index % 28 + 1:02d}T12-00-00-{owner}.jsonl"
            path.parent.mkdir(parents=True, exist_ok=True)
            source = {"subagent": {"thread_spawn": {"parent_thread_id": parent, "agent_nickname": f"worker-{index}"}}} if relation == "subagent" else {}
            payload = {"id": owner, "session_id": parent, "cwd": "/anonymous/project", "cli_version": "0.159.0", "source": "cli",
                       "git": {"branch": "fixture", "commit_hash": "0" * 40}, "recorded_instructions": "x" * padding}
            if relation == "subagent":
                payload.update(parent_thread_id=parent, agent_nickname=f"worker-{index}", source=source)
                database.execute("INSERT INTO thread_spawn_edges VALUES (?,?)", (parent, owner))
            if relation == "fork": payload["forked_from_id"] = parent
            if relation == "continuation": payload["resumed_from_id"] = parent
            first = (json.dumps({"timestamp": "2026-09-01T12:00:00Z", "type": "session_meta", "payload": payload}, sort_keys=True, separators=(",", ":")) + "\n").encode()
            sizes.append(len(first))
            event = (json.dumps({"timestamp": "2026-09-01T12:00:01Z", "type": "event_msg", "payload": {"type": "user_message", "message": f"Anonymous fixture {index}"}}, sort_keys=True, separators=(",", ":")) + "\n").encode()
            path.write_bytes(first + event)
            os.utime(path, (1800000000 + index, 1800000000 + index))
            record(path)
            database.execute("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", (owner, str(path), 1800000000 + index, (1800000000 + index) * 1000,
                             "/anonymous/project", f"DB fixture {index}", "0.159.0", f"worker-{index}" if relation == "subagent" else "", f"agent-{index}", json.dumps(source, separators=(",", ":")), "fixture", "0" * 40))
            titles.append({"id": owner, "thread_name": f"Indexed anonymous session {index}"})
        database.commit()
    finally:
        database.close()
    (home / "session_index.jsonl").write_text("".join(json.dumps(row, sort_keys=True, separators=(",", ":")) + "\n" for row in titles))
    record(home / "state_5.sqlite"); record(home / "session_index.jsonl")
    manifest = {"schema_version": 1, "anonymous_session_catalog_fixture": True, "sessions": count,
                "archived_sessions": sum(index % 5 == 0 for index in range(count)), "session_ids": (count + 9) // 10,
                "relations": relations, "padding_bytes": padding, "first_line_min_bytes": min(sizes),
                "first_line_max_bytes": max(sizes), "total_input_bytes": sum(row["bytes"] for row in files.values()), "files": files}
    write_json(output / "fixture-manifest.json", manifest)
    return manifest


def logged_run(command, output, stem, timeout):
    with (output / f"{stem}.stdout").open("w") as stdout, (output / f"{stem}.stderr").open("w") as stderr:
        result = subprocess.run(command, cwd=output, stdout=stdout, stderr=stderr, timeout=timeout)
    if result.returncode:
        raise ValueError(f"{stem} failed with exit {result.returncode}; inspect {output / (stem + '.stderr')}")


def replay(output, fixture):
    probe = output / "SessionCatalogPerformanceProbe"
    objects = sorted((output / "frozen/LensCore.build").glob("*.swift.o"))
    compiler = ["xcrun", "swiftc", "-O", "-g", "-parse-as-library", "-swift-version", "5",
                "-module-cache-path", str(output / "module-cache"), "-I", str(output / "frozen/Modules"),
                "-I", str(output / "frozen/Sources/CSQLite"), str(output / HARNESS.name),
                *map(str, objects), "-lsqlite3", "-o", str(probe)]
    logged_run(compiler, output, "compile", 120)
    logged_run(["xcrun", "dsymutil", str(probe), "-o", str(probe) + ".dSYM"], output, "symbols", 120)
    sandbox = "(version 1)(allow default)(deny network*)"
    # No runtime access to the observed Codex home, including credentials/configuration.
    sandbox += "(deny file-read* (subpath " + json.dumps(str(Path.home() / ".codex")) + "))"
    (output / "runtime-sandbox.sb").write_text(sandbox + "\n")
    runtime = ["/usr/bin/sandbox-exec", "-f", str(output / "runtime-sandbox.sb"), str(probe), str(output)]
    logged_run(runtime, output, "measurements", 600)
    rows = [json.loads(line) for line in (output / "measurements.stdout").read_text().splitlines()]
    expected_relations = {key: value for key, value in fixture["relations"].items() if value}
    if len(rows) != 12 or len({row["summary_sha256"] for row in rows}) != 1 or len({row["portable_summary_sha256"] for row in rows}) != 1:
        raise ValueError("Expected 12 consistent catalog results; inspect measurements.stdout")
    for row in rows:
        if (row["summaries"], row["indexed_titles"], row["session_ids"], row["relation_counts"]) != (
                fixture["sessions"], fixture["sessions"], fixture["session_ids"], expected_relations):
            raise ValueError("Catalog identities/titles/relations do not match the anonymous fixture")
    for relative, receipt in fixture["files"].items():
        if sha256(output / "fixture" / relative) != receipt["sha256"]:
            raise ValueError("Fixture input changed during replay: " + relative)
    groups = {}
    for label in sorted({row["label"] for row in rows}):
        group = [row for row in rows if row["label"] == label]
        groups[label] = {"samples": len(group), "wall_ms_median": statistics.median(row["elapsed_ms"] for row in group),
                         "wall_ms_min": min(row["elapsed_ms"] for row in group), "wall_ms_max": max(row["elapsed_ms"] for row in group),
                         "cpu_ms_median": statistics.median(row["cpu_ms"] for row in group),
                         "peak_rss_max_bytes": max(row["peak_rss_bytes"] for row in group)}
    write_json(output / "summary.json", {"completed": True, "calls": len(rows), "groups": groups,
               "summary_sha256": rows[0]["summary_sha256"], "portable_summary_sha256": rows[0]["portable_summary_sha256"],
               "portable_hash_normalization": "Only fixture absolute path prefixes are replaced by fixture/.",
               "all_summary_hashes_equal": True, "fixture_inputs_unchanged": True,
               "scope": "SessionEngine.catalog on anonymous fixtures; excludes SwiftUI, restoration, full session loading and reader-pool singleflight.",
               "measurement_limits": ["First actor has an empty Lens metadata cache; OS caches are uncontrolled, never claimed filesystem-cold.",
                                      "Fresh actor samples use distinct empty Lens caches; persisted samples reuse the first actor's cache when available.",
                                      "Process peak RSS includes the harness and previous samples; no allocation or heap claim.",
                                      "No comparison or performance gain is established by one replay."],
               "compiler_command": compiler, "runtime_command": runtime, "executable_sha256": sha256(probe)})


def main():
    args = arguments()
    if sys.platform != "darwin" or not Path("/usr/bin/sandbox-exec").is_file():
        raise ValueError("This private macOS replay requires sandbox-exec")
    release = release_directory()
    output = new_output(args.output)
    write_json(output / "run.json", {"status": "started", "started_unix_seconds": time.time(), "source_freeze_assumption": SOURCE_ASSUMPTION})
    try:
        freeze(output, release)
        write_json(output / "toolchain.json", {"swift": capture(["xcrun", "swiftc", "--version"]),
                   "xcode": capture(["xcodebuild", "-version"]), "sdk": capture(["xcrun", "--sdk", "macosx", "--show-sdk-version"]),
                   "os": capture(["sw_vers"]), "hardware": capture(["sysctl", "hw.model", "hw.ncpu", "hw.memsize"]),
                   "load": capture(["uptime"])})
        fixture = generate_fixture(output, args.sessions, args.padding_bytes)
        replay(output, fixture)
        write_json(output / "run.json", {"status": "complete", "completed_unix_seconds": time.time(), "source_freeze_assumption": SOURCE_ASSUMPTION})
        files = [path for path in output.rglob("*") if path.is_file() and "module-cache" not in path.relative_to(output).parts]
        write_json(output / "artifact-manifest.json", {str(path.relative_to(output)): {"sha256": sha256(path), "bytes": path.stat().st_size} for path in sorted(files)})
        print(f"Complete: 12 catalog calls, consistent anonymous summaries. Results: {output / 'summary.json'}")
        print("Prebuilt-object/source correspondence is an explicit assumption; see source-manifest.json.")
    except Exception as error:
        write_json(output / "run.json", {"status": "failed", "error": str(error), "source_freeze_assumption": SOURCE_ASSUMPTION})
        raise


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Session catalog replay: {error}", file=sys.stderr)
        sys.exit(1)
