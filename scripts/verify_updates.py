#!/usr/bin/env python3
"""Exercise real Sparkle updates using signed, isolated loopback fixtures.

Requires the already resolved Sparkle SPM artifact and a logged-in macOS GUI
session. The driver replies through SPUUserDriver; physical input, standard
dialogs, Developer ID, notarization and the production feed are not qualified.
"""
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import shutil
import socketserver
import subprocess
import threading
import time
import uuid

from sparkle_bundle import embed, find_framework, signing_commands, validate_embedded

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = ("install", "current", "cancel", "tampered-feed", "tampered-archive")


def run(args: list, **kwargs) -> str:
    return subprocess.run([str(value) for value in args], check=True, capture_output=True,
                          text=True, timeout=60, **kwargs).stdout.strip()


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def bundle_contents(app: Path) -> dict:
    return {str(path.relative_to(app)): {"link": os.readlink(path)} if path.is_symlink()
            else {"sha256": digest(path), "executable": bool(path.stat().st_mode & 0o111)}
            for path in sorted(app.rglob("*")) if path.is_symlink() or path.is_file()}


class LoopbackServer(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        # No name-service dependency for a fixture bound exclusively to loopback.
        self.server_name, self.server_port = self.server_address


def build_fixture(app: Path, number: int, installed: Path, output: Path,
                  scenario: str, identifier: str, public_key: str, feed_url: str,
                  binary: Path, artifacts: Path) -> None:
    (app / "Contents/MacOS").mkdir(parents=True)
    shutil.copy2(binary, app / "Contents/MacOS/UpdateFixture")
    info = {"CFBundleIdentifier": identifier, "CFBundleExecutable": "UpdateFixture",
            "CFBundleVersion": str(number), "CFBundleShortVersionString": f"1.0.{number}",
            "LSMinimumSystemVersion": "14.0", "CFBundlePackageType": "APPL",
            "CFBundleName": "Update Fixture", "SUFeedURL": feed_url,
            "SUPublicEDKey": public_key, "SURequireSignedFeed": True,
            "SUVerifyUpdateBeforeExtraction": True, "SUShowReleaseNotes": False,
            "SUEnableAutomaticChecks": False, "SUAutomaticallyUpdate": False,
            "SUSendProfileInfo": False,
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
            "LensUpdateReceiptDirectory": str(output), "LensUpdateApplicationPath": str(installed),
            "LensUpdateScenario": scenario}
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    embed(artifacts, app)
    validate_embedded(app)
    # The fixture must never be signed with the production app identifier.
    for command in signing_commands(app, "-")[:-2]:
        run(command)
    run(["codesign", "--force", "--sign", "-", "--identifier", identifier, app])
    run(["codesign", "--verify", "--deep", "--strict", app])


def exercise(scenario: str, output: Path, binary: Path, artifacts: Path,
             distribution: Path) -> dict:
    output.mkdir()
    (output / "events.jsonl").write_text("")
    keys = output / "keys"
    keys.mkdir(mode=0o700)
    private_key = keys / "private-key.txt"
    framework_directory = find_framework(artifacts, "arm64", "14.0").parent
    run([binary, "--generate-fixture-key", keys],
        env={**os.environ, "DYLD_FRAMEWORK_PATH": str(framework_directory)})
    private_key.chmod(0o600)
    public_key = (keys / "public-key.txt").read_text()
    served = output / "served"
    served.mkdir()
    requests: list[str] = []

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(served), **kwargs)

        def log_message(self, format, *args):
            requests.append(format % args)

    server = LoopbackServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_address[1]}"
    identifier = "fr.codexlens.update-test." + uuid.uuid4().hex
    installed = output / "Installed/Update Fixture.app"
    staged = output / "New/Update Fixture.app"
    process = None
    log = None
    try:
        for app, number in [(installed, 1), (staged, 2)]:
            build_fixture(app, number, installed, output, scenario, identifier, public_key,
                          base + "/appcast.xml", binary, artifacts)
        before = bundle_contents(installed)
        expected = bundle_contents(staged)
        archive = served / "update.zip"
        run(["ditto", "-c", "-k", "--keepParent", staged, archive])
        sign_update = distribution / "bin/sign_update"
        signature = run([sign_update, "--ed-key-file", private_key, "-p", archive])
        version = "1" if scenario == "current" else "2"
        feed = served / "appcast.xml"
        feed.write_text('<?xml version="1.0" encoding="utf-8"?>'
                        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
                        '<channel><title>Owned update fixture</title><item>'
                        f'<title>Version {version}</title><sparkle:version>{version}</sparkle:version>'
                        f'<sparkle:shortVersionString>1.0.{version}</sparkle:shortVersionString>'
                        '<sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>'
                        f'<enclosure url="{base}/update.zip" sparkle:edSignature="{signature}" '
                        f'length="{archive.stat().st_size}" type="application/octet-stream"/>'
                        '</item></channel></rss>')
        run([sign_update, "--ed-key-file", private_key, "-p", "--disable-signing-warning", feed])
        signed_feed_digest, signed_archive_digest = digest(feed), digest(archive)
        if scenario == "tampered-feed":
            feed.write_text(feed.read_text().replace("Owned update fixture", "Wrong update fixture"))
        if scenario == "tampered-archive":
            data = bytearray(archive.read_bytes())
            data[-30] ^= 1
            archive.write_bytes(data)
        log = (output / "runtime.log").open("wb")
        process = subprocess.Popen([str(installed / "Contents/MacOS/UpdateFixture")],
                                   stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 105
        marker_path = output / "relaunched.json"
        while time.monotonic() < deadline:
            events = [json.loads(line) for line in (output / "events.jsonl").read_text().splitlines()]
            if scenario == "install":
                if marker_path.exists() and any(item.get("result") == "relaunched-version-2" for item in events):
                    break
            elif process.poll() is not None:
                break
            time.sleep(0.1)
        if process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        events = [json.loads(line) for line in (output / "events.jsonl").read_text().splitlines()]
        names = [item["event"] for item in events]
        marker = json.loads(marker_path.read_text()) if marker_path.exists() else None
        after = bundle_contents(installed)
        after_info = plistlib.loads((installed / "Contents/Info.plist").read_bytes())
        run(["codesign", "--verify", "--deep", "--strict", installed])
        checks: list[dict] = []

        def check(name: str, passed: bool):
            checks.append({"name": name, "passed": bool(passed)})

        check("only-one-installed-app", len(list(installed.parent.glob("*.app"))) == 1)
        check("unique-owned-identifier", after_info["CFBundleIdentifier"] == identifier
              and identifier.startswith("fr.codexlens.update-test."))
        check("launched-owned-version-one", bool(events) and events[0].get("build") == "1"
              and events[0].get("bundle") == str(installed))
        check("explicit-check-used-real-updater", "updater-started" in names and "checking" in names)
        check("no-release-notes-view", not any(name.startswith("release-notes") for name in names))
        if scenario == "install":
            sequence = ["update-found", "download-started", "extracting", "ready-to-install", "installing"]
            check("real-installation-callback-sequence", all(name in names for name in sequence)
                  and [names.index(name) for name in sequence] == sorted(names.index(name) for name in sequence))
            check("exact-new-bundle-installed-at-same-path", after == expected and after != before)
            check("version-two-relaunched-at-original-path", marker is not None
                  and marker.get("build") == "2" and marker.get("bundle") == str(installed)
                  and marker.get("identifier") == identifier)
            check("relaunch-created-new-process", marker is not None and bool(events)
                  and marker.get("pid") != events[0].get("pid"))
            check("no-updater-errors", "update-error" not in names and "start-error" not in names)
        else:
            check("original-bundle-byte-identical", after == before)
            check("no-installation-or-relaunch", marker is None and "ready-to-install" not in names and "installing" not in names)
            if scenario == "current":
                check("up-to-date-reported", "no-update" in names and "update-found" not in names)
            elif scenario == "cancel":
                check("dismissal-preserved-original-installation", "update-found" in names and "dismissed" in names
                      and any(item.get("result") == "cancelled" for item in events))
            else:
                errors = [item for item in events if item["event"] == "update-error"]
                expected_code = 1000 if scenario == "tampered-feed" else 4005
                check("signature-failure-reported", any(item.get("domain") == "SUSparkleErrorDomain"
                      and item.get("code") == expected_code and "3002" in item.get("underlying", "") for item in errors))
            if scenario in ("current", "cancel", "tampered-feed"):
                check("archive-never-requested", not any("/update.zip" in request for request in requests))
        result = {"scenario": scenario, "bundleIdentifier": identifier, "installedPath": str(installed),
                  "beforeBuild": "1", "afterBuild": after_info["CFBundleVersion"], "relaunch": marker,
                  "signedFeedSha256": signed_feed_digest, "servedFeedSha256": digest(feed),
                  "signedArchiveSha256": signed_archive_digest, "servedArchiveSha256": digest(archive),
                  "events": events, "httpRequests": requests, "checks": checks,
                  "passed": all(item["passed"] for item in checks)}
        (output / "receipt.json").write_text(json.dumps(result, indent=2) + "\n")
        return result
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            process.wait(timeout=5)
        if log is not None:
            log.close()
        server.shutdown()
        server.server_close()
        private_key.unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, default=ROOT / ".build/artifacts")
    parser.add_argument("--output", type=Path, required=True, help="A new private output directory.")
    parser.add_argument("--scenario", choices=SCENARIOS, action="append", help="Default: all scenarios.")
    args = parser.parse_args()
    output = args.output.expanduser().resolve()
    if output.exists() or output.is_symlink():
        raise ValueError("Qualification output must be a new owned directory.")
    artifacts = args.artifacts.expanduser().resolve()
    framework = find_framework(artifacts, "arm64", "14.0")
    distribution = framework.parent.parent.parent
    if not (distribution / "bin/sign_update").is_file():
        raise ValueError("The resolved Sparkle distribution is missing its signing tool.")
    output.mkdir(parents=True)
    binary = output / "UpdateFixture"
    run(["swiftc", "-parse-as-library", "-swift-version", "5", "-target", "arm64-apple-macos14.0",
         "-F", framework.parent, "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker",
         "@executable_path/../Frameworks", ROOT / "Tests/NativeUI/UpdateMain.swift", "-o", binary])
    results = [exercise(scenario, output / scenario, binary, artifacts, distribution)
               for scenario in args.scenario or SCENARIOS]
    receipt = {"schemaVersion": 1, "sparkleVersion": "2.10.0", "method": "Real Sparkle public API-driven user driver",
               "scenarios": [{"scenario": value["scenario"], "passed": value["passed"], "checks": value["checks"]} for value in results],
               "passed": all(value["passed"] for value in results),
               "limitations": ["Physical input and standard update dialogs are not qualified.",
                               "Loopback fixtures do not qualify the production HTTPS feed or GitHub delivery.",
                               "Ad-hoc fixture signatures do not qualify Developer ID or notarization.",
                               "Cancellation dismisses an update before download; interruption during installation is not tested."]}
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Sparkle update qualification: {sum(item['passed'] for item in results)}/{len(results)} scenarios passed; {output}")
    if not receipt["passed"]:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
