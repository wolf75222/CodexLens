# Timeline render provenance

These three PNGs are unchanged native AppKit bitmap-cache renders from the V78-3 timeline appearance probe. The probe calls `bitmapImageRepForCachingDisplay(in:)` and `cacheDisplay(in:to:)` on the production `TimelineCanvas`, inside the requested Light/Dark appearance. They are not compositor screenshots or full-app captures.

The deterministic, anonymous in-memory fixture contains 1,200 root events and two descendant lanes with 40 and 12 events. No user session, account, credential, AI request or recorded command was used. The images retain the fixture's French labels and task names. They have not been cropped, retouched, annotated, generated or redrawn.

| Original filename | Published purpose | Dimensions |
| --- | --- | --- |
| [overview-light.png](overview-light.png) | Dense overview with thin colored groups and no group-number badges | 2320 × 460 |
| [intermediate-light.png](intermediate-light.png) | Separable individual event marks in Light appearance | 2320 × 460 |
| [intermediate-dark.png](intermediate-dark.png) | The same intermediate scale in Dark appearance | 2320 × 460 |

The native probe produced eight renders; only these three are published. The [manifest](capture-manifest.json) records their exact SHA-256 digests and byte sizes, the frozen source identity, and validation scope. All 108 source records matched the checkout at documentation freeze. This source is based on commit `033b2ace8dd8791c1283a20125c57760481c53a9` with the pending timeline corrections, not a clean-commit production release.

The source-matched probe replaces the app's `@main`. Its 34 passing checks are local component/navigation checks; they do not establish production-scene integration, physical input, VoiceOver, collector throughput, measured contrast or performance. The separate local Release suite executed 564 tests with five skips and zero failures. Neither result establishes GitHub CI status.

No older V38 render is used as a before-image for the current baseline. Public provenance omits machine paths, process IDs and raw test logs. The [QA note](../../QA/TIMELINE_COLORED_MARKS.md) describes grouping, zoom/dezoom, source preservation, and cache/index estimates.
