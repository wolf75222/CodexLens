# Feature catalogue screenshots

These 17 JPEGs are native-window captures made through CUA's `App.getScreenshot` API on macOS. They show the existing **0.41.0 / build 75** app in one isolated QA bundle, with English Lens labels and synthetic session data. The original screenshot bytes are retained: no AI rendering, retouching, compositing or redrawn controls.

The QA launcher verified the Swift/C/module-map source inputs against the supplied build manifest, and verified that its copied executable retained all production Mach-O sections and UUID **7C7ECD3A-984F-319A-A137-9C25E90A853F** after QA-only signing. Its preferences, observation directory, cache and archive were isolated. This identifies a local build of the release's source; it is not the downloadable CI binary or a claim of byte-identical signatures. Source commit `5378bd558f4c19259bf332da8ca3e7c833a4fd2a` contains the same app sources as tag `v0.41.0`.

Capture navigation used the app's menus, controls and accessibility actions. Only that QA process was launched, inspected and stopped. The app ran under an OS profile denying network traffic. Its sessions, messages, agents, instructions, file changes, tool outputs and token values are generated test records. Their recorded commands were never executed. No AI question was sent; the account/settings page containing live account identity was not captured. The two reused chat/diff images outside this folder retain [their original capture notes](../README.md).

## Scenarios

| Images | What the capture demonstrates |
| --- | --- |
| `getting-started.jpg`, `session-picker.jpg` | Optional introduction; an anonymous Codex deep link and the selected local source |
| `activity-overview.jpg`, `agents.jpg` | Density groups, complete event-list access, root/subagent/fork distinctions and mission links |
| `tool-output.jpg` | Recorded Markdown output, separately disclosed source coordinates and known absence of output in one representation |
| `communications.jpg`, `compaction.jpg` | Recorded routes and uncertain reception; retained text, correlation labels and available usage samples |
| `environments.jpg`, `file-reader.jpg` | Current worktree/Git identity and current file reading, separately labelled from historical content |
| `resources.jpg`, `resource-recovery.jpg` | Resource roles; a missing path and a deliberately copied filename-only candidate, not a recovered original |
| `historical-versions.jpg`, `origin.jpg` | Verified cited Git objects; recorded action, producer and parent mission links |
| `live-diff.jpg` | Three synthetic records appended during collection, then paused visual following while reading the requested patch; no file was patched |
| `conversation-export.jpg` | Main-thread message review and lexical steering cue on anonymous text |
| `settings-general.jpg`, `help.jpg` | General settings and built-in illustrated guidance |

The recovery candidate was created by copying a small fixture image into a disposable subfolder under the selected fixture scope. Its current SHA-256 is shown, but no recorded original digest was passed by the UI. One unavailable search root is retained in the coverage disclosure.

For the live demonstration, a context record, patch request and explicit synthetic output were appended to the disposable fixture's journal. This exercised passive incremental collection and recent-diff navigation; it did not launch a Codex agent, execute the patch or modify an observed user repository. Visual following was then paused and the native split resized to keep the diff readable. Other screenshots precede that append, so their event counts can differ.

Some macOS-owned labels follow the host's French language. Original French fixture text is preserved. A screenshot's visible portion is not a promise that every disclosure is expanded or every control fits without scrolling. Captions in [FEATURES.md](../../FEATURES.md) explain the selected regions and data limits.

[provenance.json](provenance.json) records filenames, JPEG dimensions, byte counts, SHA-256 hashes and UTC save times without personal machine paths, account details, process identifiers or original journals. This is documentation capture, not fresh qualification of every gesture, VoiceOver, platform version, authentication flow or performance scenario.
