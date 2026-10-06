#!/usr/bin/env python3
"""Validate release metadata or preview a future release; never tag or publish."""
import argparse
from datetime import date, datetime, timezone
import difflib
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
REPOSITORY = "https://github.com/wolf75222/CodexLens"
VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
CATEGORIES = {"Added", "Changed", "Deprecated", "Removed", "Fixed", "Security"}


def version_key(value):
    if not isinstance(value, str) or not re.fullmatch(VERSION_PATTERN, value):
        raise ValueError("Version must be major.minor.patch without leading zeros.")
    return tuple(map(int, value.split(".")))


def release_date(value):
    try:
        parsed = date.fromisoformat(value)
    except ValueError as error:
        raise ValueError("Release date must be YYYY-MM-DD.") from error
    if parsed.isoformat() != value:
        raise ValueError("Release date must be YYYY-MM-DD.")
    return parsed


def change_entries(body, allow_empty=False):
    headings = re.findall(r"^### (.+)$", body, re.MULTILINE)
    if len(headings) != len(set(headings)) or any(item not in CATEGORIES for item in headings):
        raise ValueError("Use each changelog category at most once: " + ", ".join(sorted(CATEGORIES)))
    if not headings:
        if allow_empty and not body.strip():
            return
        raise ValueError("Changelog changes need a category and at least one bullet.")
    sections = re.split(r"^### .+$", body, flags=re.MULTILINE)[1:]
    if any(not re.search(r"^- \S", section, re.MULTILINE) for section in sections):
        raise ValueError("Every changelog category needs at least one bullet.")


def comparison_links(versions):
    links = {"Unreleased": f"{REPOSITORY}/compare/v{versions[0]}...main"}
    for index, version in enumerate(versions):
        links[version] = (f"{REPOSITORY}/compare/v{versions[index + 1]}...v{version}"
                          if index + 1 < len(versions) else f"{REPOSITORY}/releases/tag/v{version}")
    return links


def parse_changelog(text):
    headings = list(re.finditer(r"^## (.+)$", text, re.MULTILINE))
    if not headings or headings[0].group(1) != "[Unreleased]":
        raise ValueError("CHANGELOG.md must begin with an Unreleased section.")
    releases = []
    history = False
    for heading in headings[1:]:
        title = heading.group(1)
        if title == "Pre-public development" and not history:
            history = True
            continue
        match = re.fullmatch(rf"\[({VERSION_PATTERN})\] - (\d{{4}}-\d{{2}}-\d{{2}})", title)
        if history or not match:
            raise ValueError("Public release headings must be [major.minor.patch] - YYYY-MM-DD.")
        version, day = match.groups()
        key, parsed_date = version_key(version), release_date(day)
        if releases and (key >= releases[-1][2] or parsed_date > releases[-1][3]):
            raise ValueError("Release versions must be unique and descending, with nonincreasing dates.")
        releases.append((version, heading, key, parsed_date))
    if not releases:
        raise ValueError("CHANGELOG.md needs at least one public release.")
    links = re.findall(r"^\[(Unreleased|" + VERSION_PATTERN + r")\]: (\S+)$", text, re.MULTILINE)
    expected = comparison_links([item[0] for item in releases])
    if len(links) != len(expected) or dict(links) != expected:
        raise ValueError("Changelog comparison links must match its public release versions.")
    first_link = re.search(r"^\[(?:Unreleased|" + VERSION_PATTERN + r")\]: ", text, re.MULTILINE)
    for index, heading in enumerate(headings):
        if heading.group(1) == "Pre-public development":
            break
        end = headings[index + 1].start() if index + 1 < len(headings) else first_link.start()
        body = text[heading.end():end].strip()
        change_entries(body, allow_empty=index == 0)
    unreleased = text[headings[0].end():headings[1].start()].strip()
    return {"versions": [item[0] for item in releases], "dates": [item[3] for item in releases],
            "unreleased": unreleased, "start": headings[0].end(), "end": headings[1].start()}


def regular_file(root, name):
    path = root / name
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise ValueError("Release files and their directories must not be symbolic links.")
    if not path.is_file():
        raise ValueError("Missing release file: " + name)
    return path.read_bytes()


def validate_repository(root, tag=None):
    root = root.resolve()
    info = plistlib.loads(regular_file(root, "Support/Info.plist"))
    version = info["CFBundleShortVersionString"]
    version_key(version)
    if not isinstance(info["CFBundleVersion"], str) or not re.fullmatch(r"[1-9][0-9]*", info["CFBundleVersion"]) or "LSEnvironment" in info:
        raise ValueError("Info.plist needs a positive build number and no QA environment.")
    changelog = parse_changelog(regular_file(root, "CHANGELOG.md").decode("utf-8"))
    if changelog["versions"][0] != version:
        raise ValueError("The newest changelog release must match Info.plist.")
    notes = regular_file(root, f"docs/releases/{version}.md").decode("utf-8")
    if not notes.startswith(f"# Codex Lens {version}\n") or not notes.split("\n", 1)[1].strip():
        raise ValueError("Release notes must identify this version and contain a description.")
    if tag is not None and tag != "v" + version:
        raise ValueError("Release tag must match the app version: v" + version)
    return info, changelog


def replace_plist_string(text, key, value):
    pattern = rf"(<key>{re.escape(key)}</key>\s*<string>)[^<]*(</string>)"
    text, count = re.subn(pattern, lambda match: match[1] + value + match[2], text)
    if count != 1:
        raise ValueError("Expected one string value for " + key)
    return text


def plan_release(root, version, day, build=None):
    root = root.resolve()
    info, changelog = validate_repository(root)
    if version_key(version) <= version_key(info["CFBundleShortVersionString"]):
        raise ValueError("The new version must be greater than the current version.")
    if release_date(day) < changelog["dates"][0]:
        raise ValueError("The release date must not precede the latest release.")
    if not changelog["unreleased"]:
        raise ValueError("There are no Unreleased changes to release.")
    build = str(build) if build is not None else str(int(info["CFBundleVersion"]) + 1)
    if not re.fullmatch(r"[1-9][0-9]*", build) or int(build) <= int(info["CFBundleVersion"]):
        raise ValueError("The build number must increase.")
    notes_name = f"docs/releases/{version}.md"
    if (root / notes_name).exists() or (root / notes_name).is_symlink():
        raise ValueError("Release notes already exist; they will not be overwritten.")
    before_info = regular_file(root, "Support/Info.plist").decode("utf-8")
    after_info = replace_plist_string(before_info, "CFBundleShortVersionString", version)
    after_info = replace_plist_string(after_info, "CFBundleVersion", build)
    before_log = regular_file(root, "CHANGELOG.md").decode("utf-8")
    after_log = (before_log[:changelog["start"]] + f"\n\n## [{version}] - {day}\n\n"
                 + changelog["unreleased"] + "\n\n" + before_log[changelog["end"]:])
    after_log = re.sub(r"^\[(?:Unreleased|" + VERSION_PATTERN + r")\]: .*\n?", "", after_log, flags=re.MULTILINE)
    links = comparison_links([version, *changelog["versions"]])
    after_log = after_log.rstrip() + "\n\n" + "".join(f"[{key}]: {url}\n" for key, url in links.items())
    parse_changelog(after_log)
    changes = re.sub(r"^### ", "## ", changelog["unreleased"], flags=re.MULTILINE)
    notes = (f"# Codex Lens {version}\n\n" + changes + "\n\n## Installation and compatibility\n\n"
             + f"Download `CodexLens-{version}-arm64.dmg` and drag Codex Lens to Applications. "
             + "The app ZIP is an alternative; the symbols ZIP, checksums and metadata accompany the download.\n\n"
             + f"See the [documentation for this version]({REPOSITORY}/blob/v{version}/README.md#requirements-and-boundaries) "
             + "for platform, Codex adapter and signing limits, and the "
             + f"[release process]({REPOSITORY}/blob/v{version}/docs/RELEASING.md) for validation details. "
             + "A changelog entry does not establish interactive or live-service qualification.\n")
    return {"Support/Info.plist": (before_info, after_info), "CHANGELOG.md": (before_log, after_log),
            notes_name: (None, notes)}


def patch_for_plan(plan):
    parts = []
    for name, (before, after) in plan.items():
        parts.append(f"diff --git a/{name} b/{name}\n")
        if before is None:
            parts.append("new file mode 100644\n")
        parts.extend(difflib.unified_diff((before or "").splitlines(keepends=True), after.splitlines(keepends=True),
                                        fromfile=f"a/{name}" if before is not None else "/dev/null", tofile=f"b/{name}"))
    return "".join(parts)


def require_clean_checkout(root, version):
    result = subprocess.run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=root,
                            text=True, capture_output=True, check=True)
    if result.stdout:
        raise ValueError("Commit or stash pending changes before writing release metadata; preview is still available.")
    result = subprocess.run(["git", "show-ref", "--verify", "--quiet", "refs/tags/v" + version], cwd=root, check=False)
    if result.returncode == 0:
        raise ValueError("This local release tag already exists; it will not be reused.")
    if result.returncode != 1:
        raise ValueError("Could not verify local release tags.")


def write_plan(root, plan):
    """Use git apply's complete-patch validation; do not stage, commit or run hooks."""
    root = root.resolve()
    for name, (before, _) in plan.items():
        target = root / name
        if any(parent.is_symlink() for parent in (target, *target.parents)) or not target.parent.is_dir():
            raise ValueError("Every release target needs an existing directory without symbolic links.")
        if before is None:
            if target.exists():
                raise ValueError("Release notes appeared after preview; refusing to overwrite them.")
        elif regular_file(root, name).decode("utf-8") != before:
            raise ValueError("Release files changed after preview; prepare the release again.")
    patch = patch_for_plan(plan)
    for extra in (["--check"], []):
        result = subprocess.run(["git", "apply", *extra, "--whitespace=error", "-"], cwd=root,
                                input=patch, text=True, capture_output=True, check=False)
        if result.returncode:
            problems = rollback_plan(root, plan) if not extra else []
            recovery = " Recovery needs manual inspection: " + ", ".join(problems) if problems else ""
            raise ValueError("Could not apply the complete release update: " + result.stderr.strip() + recovery)


def rollback_plan(root, plan):
    """Restore only our exact output after an I/O failure; preserve outside edits."""
    problems = []
    for name, (before, after) in reversed(list(plan.items())):
        target = root / name
        temporary = None
        try:
            if any(parent.is_symlink() for parent in (target, *target.parents)) or not target.parent.is_dir():
                raise ValueError("target directory changed")
            if not target.exists() and before is None:
                continue
            content = regular_file(root, name)
            if before is not None and content == before.encode("utf-8"):
                continue
            if content != after.encode("utf-8"):
                raise ValueError("content changed outside this update")
            if before is None:
                target.unlink()
                continue
            with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(before.encode("utf-8"))
                stream.flush()
                os.fsync(stream.fileno())
            os.chmod(temporary, target.stat().st_mode & 0o777)
            os.replace(temporary, target)
        except (OSError, ValueError):
            problems.append(name)
        finally:
            if temporary is not None:
                try:
                    temporary.unlink(missing_ok=True)
                except OSError:
                    problems.append(name + " (temporary recovery file)")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("check", help="Validate version, changelog and release notes.")
    check.add_argument("--tag", help="Also require this exact release tag.")
    prepare = commands.add_parser("prepare", help="Preview the next release; --write applies the update.")
    prepare.add_argument("version")
    prepare.add_argument("--date", default=datetime.now(timezone.utc).date().isoformat(), help="UTC date, YYYY-MM-DD.")
    prepare.add_argument("--build", help="Build number; defaults to current + 1.")
    prepare.add_argument("--write", action="store_true", help="Update files; never commit, tag, push or publish.")
    args = parser.parse_args()
    try:
        if args.command == "check":
            info, _ = validate_repository(ROOT, args.tag)
            print(f"Release metadata passed: {info['CFBundleShortVersionString']} (build {info['CFBundleVersion']}).")
        else:
            plan = plan_release(ROOT, args.version, args.date, args.build)
            if args.write:
                require_clean_checkout(ROOT, args.version)
                write_plan(ROOT, plan)
                validate_repository(ROOT)
                print("Updated Info.plist, CHANGELOG.md and release notes. Review the diff before committing.")
            else:
                print(patch_for_plan(plan), end="")
                print("\nPreview only. Use --write after reviewing; no tag or release has been created.")
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Release preparation failed: {error}\n")


if __name__ == "__main__":
    main()
