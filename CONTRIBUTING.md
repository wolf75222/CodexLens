# Contributing

Codex Lens is a native macOS session inspector. Changes should make existing investigation paths easier to understand while preserving source identity, historical versions, and read-only observation.

## Development setup

Use Xcode with the macOS 26 SDK and Swift 6 or newer. Clone the repository, then use its scripts:

```sh
bash scripts/build.sh
bash scripts/test.sh -c release
```

The application is created at `dist/Codex Lens.app`. For a debug build, use `bash scripts/build.sh --debug`; for a Release build with symbols, use `bash scripts/build.sh --profile`.

Inspect scripts before running additional validation tools. Some older scenario scripts are specialist local harnesses with environment-specific assumptions; do not treat every script as a general setup command.

## Scope and invariants

- Keep the product in SwiftUI/AppKit. Do not add a WebView or a custom renderer without a demonstrated requirement.
- Never resume an observed thread, rerun a recorded call, or write into an observed repository from the inspection UI.
- Preserve agent, thread, call, environment, and version identities across views.
- Distinguish recorded facts, current observations, inferred associations, and missing data.
- Keep the chat separate from observed agents. Preparing context must never send it.
- Preserve focus, selection, filters, and reading position during live updates.
- Keep long output available through paging; do not silently truncate it.
- Use short labels, system controls, SF Symbols, and English/French translations. Avoid decorative emoji in product-authored UI.

Read `AGENTS.md` and applicable local UI instructions before changing interface code. Keep business logic and transport out of view rendering. Heavy I/O, parsing, search, and diff preparation belong outside the main actor; an `async` function alone is not sufficient.

## Tests and review

Add a targeted regression test for an identity, versioning, navigation, cancellation, or permission defect. Use anonymous fixtures rather than active user sessions to force missing journals, compaction, failed calls, or concurrent edits.

For UI changes, run the actual macOS app and inspect relevant widths, light/dark appearance, keyboard access, and loading/error/empty states. A native rendering harness is useful but does not replace running the application. Explain untested interactions in the pull request.

Do not enable opt-in authenticated Codex tests in ordinary CI. They must be explicitly requested and separated from network-free fixture tests; never perform an automatic paid resend after an error.

For performance work, record the scenario, source size, build configuration, tool, and baseline. Compare the same workload before and after. Check cancellation and stale results when closing a window or changing sessions. Do not report an improvement from intuition alone.

## Pull requests

Describe the user-visible problem, resulting behavior, validation performed, and remaining limits. Include anonymized screenshots when they help explain a layout or interaction change. Keep changes bounded; separate unrelated features.

Record notable changes under **Unreleased** in [CHANGELOG.md](CHANGELOG.md), using Added, Changed, Deprecated, Removed, Fixed or Security. Leave out empty categories and routine internal cleanup. For a security fix, coordinate disclosure before describing sensitive details publicly. Keep app version bumps for a reviewed release-preparation change; see [Release maintenance](docs/RELEASING.md).

Use labels to make issues and PRs easier to find: `bug`, `enhancement`, `documentation`, `accessibility`, `ci` or `dependencies`, as appropriate. `skip-changelog` excludes routine work from GitHub-generated notes; it does not skip CI or replace the changelog policy. Dependency update PRs follow the same validation and review rules as other changes.

Never commit personal Codex journals, credentials, account details, raw investigations, absolute developer-home paths, or screenshots of real conversations. Redaction is not a substitute for inspecting what is published.

Use your own Git identity. The project does not require an AI co-author trailer.
