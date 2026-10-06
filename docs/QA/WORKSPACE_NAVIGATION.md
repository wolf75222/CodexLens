# Workspace navigation audit

The reported route was **Activity → select a message → Open in Tab → return to Activity**. The original workspace should remain easy to find, and returning should preserve the selection and reading position.

## Baseline

An independent reviewer drove the actual 0.41.0/build 75 application through macOS accessibility actions with an anonymous 600-event fixture. The source-matched QA copy retained the production executable and replaced only its application identity and disposable data locations. No user session was resumed or changed, and no AI question was sent.

Four major issues were reproduced:

| Issue | Observed behavior | Correction |
| --- | --- | --- |
| Missing return destination | Opening a reader removed the timeline, leaving only the message tab | The originating collection has a persistent return item beside readers |
| Opened tab overwritten | Back, then a normal list click changed the previously opened tab to another message | Ordinary collection selection does not create or retarget explicit reader tabs |
| Reading position lost | Back retained 19.6× zoom but changed horizontal framing and list position | Checkpoints retain timeline origin and the list’s top event plus row offset; restoration waits for layout |
| Last close clears selection | Closing the final reader cleared the activity selection | Close restores the latest originating collection and selection |

### Reader hides its origin

![Baseline: the message reader has no Activity return item](../images/navigation/before-reader.svg)

### An explicitly opened message is replaced by a normal click

![Baseline: the user-message tab now reads Assistant response](../images/navigation/before-overwritten-tab.svg)

### Closing a reader resets the independently scrolled list

![Baseline: the selected response moves to the top after close](../images/navigation/before-scroll-reset.svg)

### Closing the last reader clears selection

![Baseline: the original activity selection disappears](../images/navigation/before-cleared-selection.svg)

The annotations are vector overlays on unchanged compositor JPEGs, embedded in the SVG files. These are recordings of the baseline defects, not mockups of the fix.

## Design and implementation

The app retains navigation metadata rather than keeping every native reader and its full text in memory. Back/Forward and the collection return item restore the selected object, activity filters, timeline period/zoom/pan, event-list anchor and paused-live state. A qualified temporal midpoint retains the coordinate reference across temporary viewport and scrollbar layouts. Native list updates continue to preserve their anchor during collection.

Control-Tab cycles between the originating collection and reading tabs, including a single reader. Command-W closes the presented reader or preview, then the window when no reader is presented; it does not close an inactive tab.

The selected-item **Open in a new window** command carries the full destination, observed source, reader pool/cache and investigation archive into a distinct scene request. The new window waits for presentation indexes and revalidates its opening generation before selecting the object. Closing either window releases only its own observation leases. Missing source journals disable this new-window command for archive-only content instead of offering a nonworking action.

The production-scene replay exposed a fifth, critical issue that the initial model harness could not catch: opening a second window crashed on AppKit's toolbar-family insertion path. Both windows used the same customizable toolbar identifier while the loading window supplied a transient `operation` item absent from its idle parent. The fix scopes toolbar identity to the immutable scene request, retaining the existing item identifiers and commands. Toolbar customization is now independent per window. Strict key-window command routing remains intact; it does not fall back to a document behind Settings or a sheet.

Tab persistence includes the observed source path. Legacy entries without a source are migrated only for the default local source. Prepared explicit-target menu commands retain their source/root/window identity, so a session change while a menu is open cannot dispatch an old target into another session.

## Validation

The Release logic run executed **536 tests, four optional skips, zero failures**. The final source-matched native regression entrypoint executed **72 assertions, zero failures**, and exits nonzero if an assertion or setup/layout flow fails. Its actual AppKit event-list top row and offset remained exact through Back and both changed-filter restoration routes: offset 7, vertical origin 10217. The recorded timeline zoom remained 19.6 and horizontal origin stayed within one point of 1600. These pixel values are fixture observations, not performance goals.

Remote runs exposed four failed temporal-restoration assertions on macOS 26.6.2: zoom remained 19.6, while X drifted from 1600 to 1567, 1534, 1502 and 1471 after successive returns. Restoring raw pixels against a temporary remount width let later layout reinterpret that coordinate. Checkpoints now include a temporal midpoint qualified by source, root, extent, zoom and origin. The bounds callback accepts updates only after a matching root/restoration revision and applied clip size have been configured.

Four deterministic checks cover notifications before layout, a pending restoration, applying the saved native clip origin and ordinary user scrolling. Additional AppKit scenarios repeat five wider-to-original remounts with both overlay and legacy scrollers, and check noncentral anchored zoom followed by unchanged layout. Receipts retain expected/actual temporal values, clip sizes, geometry width and scrollbar style; CI retains failure diagnostics even when a probe fails. No global scrollbar preference is changed, and the app does not force overlay scrollers to hide the problem.

The next remote run passed the original MainView return checks but exposed a fixture race: its requested-overlay baseline still used a different effective style. AppKit [updates scroller style at runtime](https://developer.apple.com/documentation/appkit/nsscrollview/scrollerstyle) according to system preferences and input devices. The fixture now waits for the requested/effective style, matching clip/geometry width and stable layout before baselining; requested and actual styles are recorded separately. Its one-point pan tolerance is unchanged.

The harness also verified paused Live state, closing a preview back to its originating reader, closing a background reader without hiding the preview, captured-target window acceptance, distinct window navigation scopes, shared source-engine identity, surviving source reads after another observer closes, and unchanged fixture journals/worktree files. Three Core regressions cover cold aliased caches, source folders created later and blocked cache locations.

The probe replaces the production @main entrypoint. Its bitmap-cache renders omit some SwiftUI chrome and are **not** used as user-facing before/after screenshots. Actual production-interface replay and compositor captures are recorded separately below.

Physical trackpad gestures, VoiceOver, and restoring precise viewport positions across an application restart require separate qualification. Current-file readers are not silently treated as frozen historical versions.

### Reproduce the native regression

Run on a Mac with a working WindowServer; use new output directories. The probe uses anonymous fixtures, a disposable application identity and denied network access.

```sh
python3 scripts/create-origin-corpus-v21.py --output /private/tmp/lens-navigation-corpus --events 600
zsh scripts/verify-design-v07.sh --source-root "$PWD" --output /private/tmp/lens-navigation-check --corpus /private/tmp/lens-navigation-corpus --entrypoint WorkspaceNavigationV76Main.swift --after-source-freeze --run
./scripts/test.sh -c release -Xswiftc -g --jobs 3
```

CI runs the same navigation entrypoint alongside the existing native UI smoke and stores its receipt and component renders as build artifacts.

## Production-interface replay

The independent reviewer replayed the first four defects in the real application. Activity return and Back kept the user selection, 19.6× zoom and list position; selecting the following response retained the opened user-message tab; the scrolled list kept its exact visible range after opening/closing a reader; closing inactive and final readers preserved the workspace selection. Native window resizing and light/dark appearances were also inspected. These captures precede the separate toolbar-family crash fix; their scope is the activity/tab return behavior.

![The reader keeps an explicit Activity return item](../images/navigation/after-reader.jpg)

![Returning from the reader preserves the independently scrolled list](../images/navigation/after-return.jpg)

![The activity workspace remains readable in a narrower native window](../images/navigation/after-narrow.jpg)

Capture identities, hashes and exclusions are in the [manifest](../images/navigation/capture-manifest.json). Captures involving a relaunch or stale application binding were excluded.

The added **WorkspaceSceneV76Main** regression passed **24 assertions** through two real SwiftUI scenes using the production window wrapper, commands and `openWindow` handler. It verified distinct stable native toolbar identifiers, the selected message in the child, the parent's selection and 19.6×/pan position, both windows' loading transitions, key-window command availability, shared-reader identity and unchanged fixture files. Production cleanup stopped both observers and unregistered both windows. The probe did not finish its native termination request within the launcher's three-second allowance; the launcher stopped only its own process. Native application quit is therefore unqualified separately from these successful scene assertions.

```sh
zsh scripts/verify-design-v07.sh --source-root "$PWD" --output /private/tmp/lens-scene-check --corpus /private/tmp/lens-navigation-corpus --entrypoint WorkspaceSceneV76Main.swift --after-source-freeze --run
```

The final compositor replay after toolbar isolation remains blocked by the locked Mac. No unlock bypass was attempted. The real-scene regression creates its own fixture windows programmatically; it does not synthesize physical input or claim a compositor capture. Temporary diagnostic logging used to identify the crash was removed from the delivered app.
