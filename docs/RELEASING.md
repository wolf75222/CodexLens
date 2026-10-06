# Release maintenance

`Support/Info.plist` is the app version source of truth. Public releases use `major.minor.patch` and a separate increasing build number. Before 1.0, a minor release may change compatibility. Dates in the changelog use UTC.

## Record changes

Add concise, user-facing entries to `CHANGELOG.md` under **Unreleased**, grouped as Added, Changed, Deprecated, Removed, Fixed or Security. Omit empty categories. Describe the result rather than listing commits. Do not present private development builds as published releases, or invent historical dates.

Routine internal maintenance can omit an entry. Include tooling changes that affect contributors or installation. Never put personal session details or an undisclosed vulnerability in the changelog; use [private security reporting](../SECURITY.md).

## Prepare a version

Commit the reviewed changes first. The preparation tool uses only Python's standard library and Git. It previews the complete update by default; the example below does not create a release:

```sh
python3 scripts/release_notes.py prepare 0.41.1
```

Choose the next version deliberately; do not reuse the example after that version exists. The date defaults to today in UTC, and the build number defaults to the current build plus one. `--date YYYY-MM-DD` and `--build NUMBER` are explicit overrides.

After reviewing the preview, apply it on a clean checkout:

```sh
python3 scripts/release_notes.py prepare 0.41.1 --write
python3 scripts/release_notes.py check
git diff -- Support/Info.plist CHANGELOG.md
```

The tool moves Unreleased changes into a dated section, leaves an empty Unreleased section, refreshes comparison links, updates the plist without reformatting it, and creates `docs/releases/<version>.md`. It rejects nonincreasing versions/builds, empty changes, existing notes or local tags, and changes to input files during preparation. `--write` recomputes the preview from the clean checkout; review it again if commits or options changed. Target directories and the complete patch are checked before writing. A failed write attempts to restore this invocation's changes; outside edits are preserved and unresolved recovery is reported. The tool never stages, commits, tags, pushes, publishes, installs packages or contacts a service.

Review the new notes as well as the diff: new notes are untracked until added. Edit them to include the actual compatibility, signing and validation limits for this release. Generated notes are a starting point, not a qualification receipt. Commit the three files together in the release-preparation pull request.

## Local verification

```sh
python3 scripts/check-repository.py
bash scripts/test.sh -c release
python3 -m unittest discover -s scripts/tests -v
bash scripts/build.sh --profile
bash scripts/package-release.sh --app 'dist/Codex Lens.app' --output dist/release
```

Packaging requires Python 3.11 or later. The wrapper creates an isolated `.venv-release` and installs the three build-only packages using their pinned wheel hashes. A normal app build does not need them. Regenerating icon or installer artwork additionally requires `rsvg-convert`; generated image assets are committed.

Package only a clean committed revision. For a disposable local installer preview, use `--allow-dirty` and a new output directory; its metadata records the dirty state. Never publish that preview as a tagged release. Packaging refuses an existing nonempty output directory, QA bundles, wrong architecture, mismatched tags/versions, missing symbols and invalid signatures.

## Publish

Merge the reviewed release-preparation change into `main`. Update the local checkout with `git pull --ff-only` and wait for **Build, test and package** on that exact main revision to pass. Confirm a clean tree and derive the tag from the validated plist rather than copying a past version:

```sh
python3 scripts/release_notes.py check
git status --short --branch
version=$(python3 -c 'import plistlib; print(plistlib.load(open("Support/Info.plist", "rb"))["CFBundleShortVersionString"])')
git tag -a "v$version" -m "Codex Lens $version"
git push origin "v$version"
```

The Release workflow first validates the tag against the plist, changelog and notes and checks that its commit belongs to `main`. It then reruns the shared validation workflow on that tag. Only after successful verification does its publishing job download the matching commit's artifacts, recheck checksums and provenance, create a draft release with assets, and publish it. It does not replace an existing release or tag. If publication fails after draft creation, inspect and complete or discard that draft explicitly before retrying.

Publication uses the curated `docs/releases/<version>.md` file. `.github/release.yml` supplies categories only for GitHub's optional **Generate release notes** action; it does not update the changelog or replace the curated release body. Labels `bug`, `enhancement`, `documentation`, `ci` and `dependencies` organize those generated notes. `skip-changelog` omits a PR only from generated notes, not from review or CI.

Keep main's required checks and review rules enabled. Dependency update PRs run the same CI and require review; they are not automatically merged. A documentation or maintenance change does not require publishing a new app binary.

The installer is a compressed read-only DMG with an Applications link and a fixed Finder icon layout. Validation mounts only the generated image, verifies bundle resources and signature against the app ZIP, checks the dSYM UUID and the installer layout, then detaches the owned mount.

## Signing and notarization

Community CI signs locally, with no Developer ID certificate or account secrets configured. This is stated in the README and release notes.

For an owner-managed signed release, explicitly set `LENS_SIGNING_IDENTITY` to an installed Developer ID Application identity before building. The build adds hardened runtime and a timestamp. Set `LENS_NOTARY_PROFILE` to an existing `notarytool` keychain profile when packaging. The packager requires Accepted status, staples and validates the app ticket, then does the same for the DMG. No Apple credentials are stored in this repository and no notarization is attempted by default.

Provision credentials outside the repository using Apple's documented tooling. Do not add certificate files, passwords or private keychain exports to Git. Current public CI does not claim to qualify this optional signing path.
