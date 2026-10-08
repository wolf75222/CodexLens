# Updates and removal

## Updating an installed app

Install Codex Lens in **Applications** and run that copy. Use the toolbar’s
download-arrow button or **Settings → General → Update app…** to open the native
update flow. **Codex Lens → Check for Updates…** offers the same command.
The updater checks the stable GitHub release feed. Update preferences are in
**Settings → General**. An update replaces the installed application in its
current location; it does not create another version alongside it. Sparkle
downloads, validates and installs the update, then relaunches Lens when you
choose to install.

Automatic checks are off by default and can be enabled in settings. They check for a release; they do
not silently install it. Local data and preferences stay in place. An update
does not modify the sessions and repositories Lens inspects or the installed
Codex CLI.

Older builds without the updater, including 0.41.0, need one manual installation
of an updater-enabled build. Copy **Codex Lens.app** from its DMG into
**Applications** and choose **Replace** if Finder asks. Future signed stable
releases can then be installed from within Lens. Running directly from a DMG,
a read-only folder or an app-translocated location is not a supported update
installation. Install the app in Applications before checking.

The release channel currently targets Apple Silicon and macOS 14 or later.
Community artifacts are ad hoc signed unless their release notes explicitly
state Developer ID signing and notarization. A Sparkle update signature
authenticates the update publisher; it does not replace Apple notarization.

## Removing Lens

Use **Settings → General → Maintenance → Uninstall Codex Lens…**, or quit Lens and move **Codex Lens.app** from
**Applications** to the Trash. Application removal preserves Lens data and
preferences by default. It leaves the Codex CLI, its login, recorded sessions and inspected
repositories alone. Reinstalling Lens can reuse the retained local data.

Do not delete a Codex home directory to uninstall Lens. Lens data is separate
from the sources it reads. The removal UI explains what will be moved before
you confirm. An optional cleanup checkbox moves only the listed default Lens
data locations to the Trash and clears Lens preferences. Exports and custom
data locations are retained. Leave that checkbox off to keep your local
investigations and reading index for a later reinstall.

## How updates are published

Lens uses [Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0),
whose macOS 12 minimum is compatible with Lens's macOS 14 target. Its package is
pinned to that exact version. The stable feed is:

```
https://github.com/wolf75222/CodexLens/releases/latest/download/appcast.xml
```

Every future stable release includes its own signed `appcast.xml` and full
`CodexLens-VERSION-arm64.zip`. The feed references that version's exact GitHub
asset URL. It contains the bundle build number, displayed version, minimum
macOS version, architecture restriction, byte length and Ed25519 archive
signature. Build numbers must increase between releases; changing only the
displayed version does not make an update available.

The app requires a signed feed and verifies the update before extracting it.
Both signatures are checked against the public key embedded in Lens. No
unsigned fallback is published. `SUSignedFeedFailureExpirationInterval` is
explicitly zero: signature failures continue to fail even after a long period
without a successfully verified feed. This disables Sparkle's timed fallback
for unsigned feed content. The publisher rejects builds that change that
setting. This channel does not load external release
notes into the app; complete notes remain on the GitHub release page.

The [release workflow](../.github/workflows/release.yml) accepts version tags
only when their commit is on `main`. It runs the full reusable CI first and
then checks the downloaded artifacts against the exact tag revision, version
and checksums. Publication uses the official Sparkle tools from the 2.10.0
distribution, pinned by SHA-256:

```
c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c
```

`scripts/update_appcast.py release` isolates the full ZIP, calls the official
`generate_appcast` with delta generation disabled, signs the feed with
`sign_update`, and verifies the feed and archive using macOS CryptoKit and the
app's public key. It also checks the actual ZIP's bundle identity, version,
updater configuration and ARM64 executable header against the packaged release
metadata. The signed feed joins the release checksums before any upload. The
workflow refuses to replace an already published release automatically.

## Signing key setup for maintainers

The private signing key is not part of the repository, app bundle, Lens data or
release artifacts. Generate it with Sparkle's official `generate_keys` tool in
a dedicated Keychain account and put only its public key in `Support/Info.plist`.
Store the exported private seed as the GitHub Actions repository secret
`SPARKLE_ED25519_PRIVATE_KEY`. Keep a secure backup; losing the key can prevent
installed builds from accepting future updates.

The workflow gives that secret only to the signing step. The Python helper
passes it through stdin to official Sparkle tools, removes it from child
process environments, and does not relay signing-tool output on failure.
Missing keys, malformed keys, a public-key mismatch or invalid signatures stop
publication. Checks and installation never send this private key to the app.

For the first updater-enabled build, an empty signed bootstrap feed may be
added to the existing stable release. It advertises no legacy unsigned update;
it allows the new app to check successfully before its first newer stable
release exists. A successful check then reports that no update is available.
The next verified stable tag on `main` publishes the normal feed. Branch builds
and pull requests do not become available updates automatically.

Tests in `scripts/tests/test_update_appcast.py` cover release identity, exact
asset URLs and lengths, architecture, archive tampering, unsigned/malformed
feeds, expiry or HTML-release-note configuration changes, signing failures and actual Ed25519 verification against a public
offline test vector. A published production update must also be checked with
an older installed application; these tests do not establish Gatekeeper,
administrator authorization or Developer ID/notarized upgrade behavior.

See [Releasing](RELEASING.md) and [Sparkle's signed-feed guidance](https://sparkle-project.org/documentation/#signing-feeds-optional)
for the remaining release steps.
