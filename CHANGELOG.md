# Changelog

Notable changes to Codex Lens, organized by release. Dates use UTC. This file follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the app version uses `major.minor.patch`, with a separate increasing build number. Before 1.0, minor releases may change compatibility.

Compatibility and test coverage are documented in each release's notes. A listed feature does not imply qualification on every macOS release or Codex version.

## [Unreleased]

### Fixed

- Keep custom control accents consistent across settings navigation, session dialogs, search focus, text selection and content indicators. Native System mode continues to follow macOS.
- Let Open Session cancel a Lens read and keep a startup restoration from overriding an explicit session choice.

### Changed

- Reuse compact, source-validated session metadata across refreshes and restarts. Bound its memory estimate and disk namespace to 8 MiB, revalidate source stamps, and merge current titles, database relations and ownership exclusions.
- Reduce first-record scanning, hash formatting, regular-expression compilation and temporary JSON retention during catalog loading. Share overlapping catalog requests and drain cancelled readers before cleanup.

## [0.42.0] - 2026-10-06

### Added

- Native signed updates from GitHub releases, with manual checks and optional automatic checks. Updates replace the current installed app and preserve its data.
- A review-first uninstall flow in Settings, keeping local data by default and offering recoverable, narrowly scoped cleanup.

- Session curves in Activity: recorded events, tool/MCP calls, requested file changes, reported errors, waits and identified compactions, with interval/cumulative counts, keyboard-accessible values and linked period inspection.
- Open a selected timeline event or reading tab in an independent inspection window using the same observed source.
- Detailed feature catalogue with native macOS screenshots, entry points, keyboard commands and availability limits.
- Preview-first release preparation that updates the app version, build number, changelog and release notes together without creating a tag or publishing.
- CI checks for release metadata consistency, changelog structure and version/tag mismatches.
- Release-tag validation that rejects commits outside the main branch before building or publishing.

### Changed

- Keep the originating collection available beside reading tabs; ordinary row selection no longer replaces an explicitly opened tab.
- Include the collection in keyboard tab cycling and the Window menu. Command-W closes the presented reader or window, never a background reader.
- Separate public releases from private development history, and add dates and comparison links.
- Document the contribution and release workflow, including change categories and GitHub labels.

### Fixed

- Keep separated timeline events visible at intermediate zoom and preserve event-type colors inside dense groups.
- Redraw viewport-dependent timeline content after restoring a reader's browsing position, while preserving zoom, selection and scroll anchors.
- Start new installations in English with Dark appearance while preserving saved language and theme choices.
- Move Unified / Side by side diff presentation into the existing More menu to keep the header compact.
- Retire prepared activity and timeline data before switching to another source with the same session ID.
- Restore the visible curve-table period after Back and preserve manual reading position when updates change interval resolution.
- Restore the activity selection, list scroll anchor, timeline framing, filters and paused live state when returning from a reading tab.
- Ignore temporary AppKit clip positions before timeline layout or while a saved position is waiting to be restored.
- Preserve the timeline's time coordinate when viewport or scrollbar widths change while returning to a reader's originating view.
- Keep event-centering inside the timeline bounds, avoiding empty space before the earliest event and a different framing on return.
- Closing the last reading tab returns to the originating collection without clearing its selection.
- Scope stored reading tabs and prepared context-menu commands to the observed source, preventing same-ID sessions in different source folders from sharing destinations.
- Wait for presentation indexes before opening a selected item in another window, and reject stale window openings.
- Closing a temporary live preview restores the reader it covered; closing a background reader leaves the preview visible.
- Keep one shared session reader when a cache under an aliased directory is created after the first acquisition.
- Give each session window a stable toolbar identity, preventing an AppKit toolbar-family exception when a loading child opens beside an idle parent.

## [0.41.0] - 2026-10-05

First public community release.

### Added

- Native macOS session inspection: activity, agents, calls, environments, resources, recorded changes and isolated investigation chat.
- English installation, usage, architecture, contribution and security documentation with anonymous interface screenshots.
- CI and verified release packaging: a drag-to-Applications disk image, app ZIP, matching symbols, checksums and source metadata.

### Fixed

- Coalesce pending local Codex connections instead of launching duplicate subprocesses.
- Prevent delayed connection launches from surviving shutdown or publishing stale account state.
- Preserve a noncancelled connection waiter when another waiter is cancelled, while allowing shutdown to close the owned process.

## Pre-public development

These versions were local deliveries, not published GitHub releases. Their dates and full private validation receipts are not included here.

### 0.40.6

- Simplify first-use onboarding to one primary action per step.
- Remove repeated actions and labels from the session picker and empty state.

### 0.40.5

- Thicken the app icon's magnifier, widen its handle, and smooth the join.
- Update both appearance variants while keeping the dark icon as the default.

### 0.40.4

- Automatically check the installed Codex and its existing ChatGPT connection when opening the chat or AI settings.
- Distinguish a local process error from a signed-out account and show the appropriate retry or connection state.

### 0.40.3

- Remove repeated transmission notices from the chat composer while retaining the explanation in AI settings.

### 0.40.2

- Accept `codex://threads/<thread-id>` links in the session picker.
- Make the observed source directory visible and offer a route back to personal Codex sessions.
- Preserve the current session while a new opening is pending or fails.

### Earlier work

Before public repository setup, development added passive live activity, linked agent/call/file navigation, historical version inspection, local conversation export, an isolated Codex chat, English/French settings, and native macOS menus and panels. Earlier private development receipts are not part of the public repository.

[Unreleased]: https://github.com/wolf75222/CodexLens/compare/v0.42.0...main
[0.42.0]: https://github.com/wolf75222/CodexLens/compare/v0.41.0...v0.42.0
[0.41.0]: https://github.com/wolf75222/CodexLens/releases/tag/v0.41.0
