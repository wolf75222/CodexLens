# Architecture

Codex Lens is a session inspector with an optional, isolated investigation chat. The product is a native SwiftUI/AppKit executable backed by a reusable `LensCore` module. There is no WebView, remote production SwiftPM dependency, or custom GPU renderer.

## Modules

| Location | Responsibility |
| --- | --- |
| `Sources/LensCore` | Session adaptation, source references, incremental indexing, timeline/diff models, version verification, local files, investigation transport and storage |
| `Sources/CodexLens` | macOS scenes, shared selection, window navigation, native views, menus, AppKit readers and pane integration |
| `Sources/LensInspect` | Read-only command-line inspection and diagnostic workloads |
| `Tests/LensCoreTests` | Data, identity, navigation, paging, security-boundary and transport tests |
| `Tests/NativeUI` | Native component and interaction harnesses, separate from full interactive app testing |
| `Assets` / `Support` | Icon variants, English localization, help images, application metadata |
| `scripts` | Build, test, release packaging, and focused validation tools |

Production uses Apple frameworks and system SQLite. Editor-library experiments are not product dependencies.

## Passive observation

`CodexSourceLocation` chooses the observed Codex directory. By default it uses `CODEX_HOME`, or `~/.codex` when unset; `LENS_CODEX_HOME` can select a separate observation source. This does not choose or import the investigation account's credentials.

`SessionEngine` reads available local session metadata and rollout journals. It resumes from verified source positions, checks source changes, and deduplicates protocol identities. `SessionReaderPool` shares readers for equivalent source/cache/session combinations; UI state remains local to each window.

Collection and derived indexing run in actors. The UI store publishes prepared state to the main actor. Source content is paged separately from the timeline's index, so opening a reader does not require rendering a whole journal. Source references remain attached to records: path, line, byte range, source identity, and known timestamps.

The observer does not connect to, resume, or instrument an external active Codex process. Live mode polls persisted records. The private App Server subprocess described below belongs to the chat, not the observer.

## Identity and navigation

The central unit is a session family supported by recorded relationships. Session/thread identifiers, turns, agents, and tool calls retain separate identities. Sharing a repository or a nearby timestamp does not make two sessions related.

Events, agents, environments, resources, file changes, and instruction links use the same references across views. `InspectionNavigation` preserves selection history and reading tabs. Each window owns its navigation; shared bookmarks do not merge the windows' selections.

A file identity includes its environment. Two worktrees with `src/File.swift` are not interchangeable. Historical environment references remain valid references even after their directories disappear.

## Historical content

The model separates:

1. A requested patch.
2. Its recorded tool result.
3. Observed or recorded content versions.
4. A current filesystem observation or current Git diff.

Verified Git reads resolve the recorded commit and tree entry before using a blob. Reconstruction happens in memory and must match a recorded target hash. A reconstructed content version does not establish authorship or prove execution of the patch. Missing historical bytes are never replaced with the current file under a historical label.

Record readers verify source identity while paging; source mutation produces an explicit error. Raw-view redaction means the displayed text is not a byte-for-byte forensic export.

## Isolated chat

`CodexInstallation` discovers executable candidates and qualifies their version. `CodexInvestigationEngine` communicates with a private `codex app-server` subprocess through newline-delimited JSON over stdio. The adapter currently accepts **0.159.2** only.

Official `account/read` metadata verifies that the active account is ChatGPT. Codex manages its own credentials; Lens does not parse or copy `auth.json`. The model catalogue and rate-limit data are shown only when supplied by the interface. A catalogue response is not proof that a model request will succeed.

`EvidenceCapsule` is the internal name for the immutable selected-context package. It contains source references, captured content, known versions, and omissions. It is frozen per send and supplies response-citation addresses. The UI calls this **context** or **sources**.

`CodexInvestigationRegistry` records which investigation thread belongs to which Lens chat. The observer excludes those threads and private investigation workspaces. Follow-ups target this explicit identity rather than the newest Codex session.

The engine applies and verifies a named permission profile: no write access to observed repositories, tool networking disabled, readable content restricted to the private workspace, and global hooks, MCP servers, plugins, and connectors disabled. Additional macOS restrictions prevent inherited `AGENTS.md` instructions from being loaded. If the installed interface cannot verify those restrictions, connection is refused. These controls are not just a prompt asking the model to be careful.

Responses are provisional until the correct turn reports successful completion. EOF, interruption, authentication failure, quota errors, and cancellation do not become successful answers. Drafts remain available; inference is not automatically retried.

## Storage and limits

| Data | Default location / budget |
| --- | --- |
| Persistent observation index | `~/Library/Caches/CodexLens/Index-v1`, 64 MiB cache budget |
| Investigation records | `~/Library/Application Support/CodexLens/Investigations`, 32 MiB archive budget |
| Selected chat context | 256 KiB total; 64 KiB JSON per entry |
| Journal index | 150,000 events per journal; oversized records have explicit coverage limits |
| Git blobs and diffs | 8 MiB per read; explicit refusal above the limit |

These are storage/read bounds, not a bound on the application's total RAM use. A large session family or directory can still require substantial memory and initial indexing time. Cache eviction must not silently replace content or hide a missing-data state. Sources remain read-only.

`LENS_CACHE_DIRECTORY` and `LENS_ARCHIVE_DIRECTORY` isolate diagnostics and anonymous fixtures. Public examples must not point to personal sources. Source logs, account metadata, live conversations, or unredacted profiling receipts must not be added to the repository.

## Compatibility and validation

The deployment target is macOS 14. SwiftUI's newer glass APIs are gated on macOS 26; code, logs, and diffs keep stable backgrounds. The build requires an SDK that knows those APIs, even when targeting an older OS.

Tests cover synthetic and anonymized persisted data. Native rendering harnesses can check layout and command dispatch but do not by themselves qualify physical trackpad input, VoiceOver workflows, window restoration, or the complete running app. Local Codex metadata probes and real inference checks are opt-in; ordinary CI must not require a logged-in user or submit a model request.

CI status belongs to its exact commit and workflow run. Performance improvements require repeatable before/after scenarios, using signposts and Instruments where available; compilation, passing tests, or a screenshot is not a performance measurement.
