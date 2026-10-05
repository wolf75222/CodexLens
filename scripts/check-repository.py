#!/usr/bin/env python3
"""Check the public source inventory, documentation links and pinned workflows."""
from pathlib import Path
import ast
import json
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
    files = [ROOT / name for name in tracked if name]
    errors = []
    forbidden = {"Documentation", "Delivery-v26", "Prototypes", ".agents", ".build", "dist", ".venv-release"}
    for path in files:
        relative = path.relative_to(ROOT)
        if relative.parts[0] in forbidden or path.name in {"auth.json", ".env"}:
            errors.append(str(relative) + ": private/generated file is tracked")
        if path.is_symlink() or path.stat().st_size > 20 * 1024 * 1024:
            errors.append(str(relative) + ": unexpected symlink or large file")
        if path.suffix == ".py":
            ast.parse(path.read_text(), filename=str(relative))
        if path.suffix == ".json":
            json.loads(path.read_text())
        if path.suffix == ".md":
            for target in re.findall(r"!?\[[^\]]*\]\(([^)]+)\)", path.read_text()):
                target = target.split("#", 1)[0].strip("<>")
                if not target or "://" in target or target.startswith("mailto:"):
                    continue
                if not (path.parent / target).exists():
                    errors.append(str(relative) + ": missing local link " + target)
        if path.suffix in {".yml", ".yaml"} and relative.parts[:2] == (".github", "workflows"):
            for action in re.findall(r"uses:\s*([^\s#]+)", path.read_text()):
                if not action.startswith("./") and not re.fullmatch(r"[\w.-]+/[\w.-]+@[0-9a-f]{40}", action):
                    errors.append(str(relative) + ": action is not pinned to a full SHA")
    info = plistlib.loads((ROOT / "Support/Info.plist").read_bytes())
    version = info["CFBundleShortVersionString"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or "LSEnvironment" in info:
        errors.append("Support/Info.plist: invalid release version or QA environment")
    if not (ROOT / f"docs/releases/{version}.md").is_file():
        errors.append("Missing release notes for " + version)
    if errors:
        raise SystemExit("\n".join(errors))
    print(f"Public repository checks passed: {len(files)} files, version {version}.")


if __name__ == "__main__":
    main()
