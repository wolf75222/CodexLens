# Initial public-release code review

This bounded review covered local Codex subprocess ownership, completion/error handling, authentication isolation, passive collection and historical-source access. It is not a blanket correctness or performance certification.

## Fixed lifecycle defects

`Sources/LensCore/CodexInvestigationEngine.swift` previously allowed an actor suspension during connection launch to install a child after shutdown. Concurrent metadata checks could also launch duplicate children. A cancelled metadata waiter could leave a completed but unpublished child callable after shutdown.

The engine now shares one pending connection, revokes its ownership before shutdown suspends, rejects/closes abandoned results, and adopts a valid completed child before checking caller cancellation. Error cleanup targets the captured server and cannot close a replacement connection. These changes do not weaken sandbox, authentication or observed-thread restrictions.

Four synthetic JSONL subprocess regressions cover delayed shutdown, duplicate launches, cancellation cleanup and preservation of a noncancelled peer. Before the fixes, the first pair failed with three assertions and the cancellation pair failed with one assertion. Afterward, the focused engine/transport/registry/shared-reader suite executed 44 tests: 41 passed, three live-inference tests skipped, zero failures.

The integrated local Swift suite subsequently executed 533 tests, with four intentional live/account skips and zero failures. Public CI runs its own checks on the exact pushed commit; consult Actions for the remote result.

## Remaining bounded concern

`SessionEngine.rawChunk` reads a raw byte range without comparing `SourceRef.sha256`. No production SwiftUI caller was found; current inspectors use the verifying recorded pager. A future raw-chunk UI or public caller must preserve source validation without hashing the whole event on every page. This helper was not rewritten as part of the lifecycle patch.

## Publication and release review

Two personal session identifiers were replaced by anonymous fixture IDs. Local development history, raw reports, traces, prototypes and hardcoded historical packaging scripts are excluded from Git. Icon copyright attribution is retained separately from the original code's MIT license.

The release path pins GitHub Actions by full SHA, gives write permission only to the final publisher, records source revision and dirty state, checks tag/version consistency, and validates the DMG, ZIP, dSYM and exact artifact checksums. Installer boundary tests reject QA configuration, links impersonating bundles, path traversal, unlisted data and changed bytes.

No credentials were read, no question was sent to a model, and no observed user session was resumed or changed during the review. No new performance gain, live-service, Intel, macOS 14 runtime or VoiceOver result is claimed.
