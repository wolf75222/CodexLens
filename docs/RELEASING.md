# Release maintenance

The version in `Support/Info.plist` is the release source of truth. Bump its version and build number, update `CHANGELOG.md`, and add `docs/releases/<version>.md` before tagging.

## Local verification

```sh
bash scripts/test.sh -c release
python3 -m unittest discover -s scripts/tests -v
bash scripts/build.sh --profile
bash scripts/package-release.sh --app 'dist/Codex Lens.app' --output dist/release
```

Packaging requires Python 3.11 or later. The wrapper creates an isolated `.venv-release` and installs the three build-only packages using their pinned wheel hashes. A normal app build does not need them. Regenerating icon or installer artwork additionally requires `rsvg-convert`; generated image assets are committed.

Package only a clean committed revision. For a disposable local installer preview, use `--allow-dirty` and a new output directory; its metadata records the dirty state. Never publish that preview as a tagged release. Packaging refuses an existing nonempty output directory, QA bundles, wrong architecture, mismatched tags/versions, missing symbols and invalid signatures.

## Publish

Push the reviewed main branch and wait for its exact GitHub CI revision to pass. Then create the matching version tag:

```sh
git tag -a v0.41.0 -m 'Codex Lens 0.41.0'
git push origin v0.41.0
```

The Release workflow reruns the shared validation workflow on the tag. Only after successful verification does its publishing job download the matching commit's artifacts, recheck checksums and provenance, create a draft release with assets, and publish it. It does not automatically replace an existing release. If publication fails after draft creation, inspect and complete or discard that draft explicitly before retrying.

The installer is a compressed read-only DMG with an Applications link and a fixed Finder icon layout. Validation mounts only the generated image, verifies bundle resources and signature against the app ZIP, checks the dSYM UUID and the installer layout, then detaches the owned mount.

## Signing and notarization

Community CI signs locally, with no Developer ID certificate or account secrets configured. This is stated in the README and release notes.

For an owner-managed signed release, explicitly set `LENS_SIGNING_IDENTITY` to an installed Developer ID Application identity before building. The build adds hardened runtime and a timestamp. Set `LENS_NOTARY_PROFILE` to an existing `notarytool` keychain profile when packaging. The packager requires Accepted status, staples and validates the app ticket, then does the same for the DMG. No Apple credentials are stored in this repository and no notarization is attempted by default.

Provision credentials outside the repository using Apple's documented tooling. Do not add certificate files, passwords or private keychain exports to Git. Current public CI does not claim to qualify this optional signing path.
