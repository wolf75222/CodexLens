# Session curves

The Charts mode belongs to Activity and uses its session, agent, environment, event-type, search and period scope. It does not create a separate dashboard or observe another session process. A selected interval opens the existing timeline; navigation history preserves the selected metric, cumulative mode, date and values-panel visibility.

## Data meanings

| Metric | Counted item |
| --- | --- |
| Events | Canonical recorded events visible in the activity scope |
| Tool calls | Recorded invocation identity, qualified by agent; results do not add invocations |
| MCP calls | Invocations with an explicit qualified MCP name; source-code mentions do not count |
| Requested changes | A requested file target per logical call and environment; applied/current file state is not inferred |
| Reported errors | Known failure records associated with a call where identifiers allow it |
| Recorded waits | Wait calls or standalone wait events; idle duration is not inferred |
| Compactions | Operations identified by the existing canonical compaction index |

Undated or unsupported timestamps remain counted separately and are not drawn at an invented time. Source coverage passes through from the session. Zero matching records in an interval is not proof that the interval was fully observed.

Completed-item failures use their recorded end rather than being placed at the invocation's start. An explicit result record takes priority. If a completion date is missing, that failure remains unplotted even when its invocation has a known start.

UTC-aligned bins use a bounded adaptive resolution, retaining empty intervals and at most 240 plotted buckets. The values table shares the chart selection and exposes interval/cumulative counts. Drilldown retains source-event identities independently of plotted mark density. Bucket periods are half-open; their timeline filter ends immediately before the next bucket's start.

## Component decision

The implementation uses the SDK's native Swift Charts framework, without third-party dependencies, WebView or custom GPU code. Apple's [chartXSelection](https://developer.apple.com/documentation/swiftui/view/chartxselection(value:)) is available on macOS 14, matching the deployment target. Compilation uses Xcode 26.6, Swift 6.3.3 and SDK 26.5; that does not qualify every interaction on macOS 14.

The Core projection handles metadata counting and deduplication. SessionPresentationBuilder prepares it on its actor executor, reuses it for agent-tree-only query changes, and publishes it through the existing cancellable generation mechanism. Switching the visible metric or cumulative mode only reads the bounded prepared buckets. Source journals are not reopened by a chart selection.

## Verification

Core regressions exercise call/result mirrors, repeated calls across agents, explicit MCP naming, distinct worktrees, missing timestamps, compaction identity, long gaps, bounded bucket counts and source-ID drilldown. Presentation regressions check shared filter scope, revisions, root changes and independent agent-tree queries.

The dedicated anonymous corpus adds dated and undated MCP calls, a recorded failure, waits, an incomplete last journal line and another source with the same root ID. No recorded command is executed. The native entrypoint checks chart/table selection, period navigation and Back, reader tabs, changed sources, stale commands, and a clearly labeled in-memory model publication.

Local Release validation executed **557 tests, five optional skips and no failures**. The final native curve entrypoint passed **35 assertions**, including selecting and fully revealing an initially offscreen table row, changing that selection from the chart state, and restoring the curve after period inspection. Its light/dark/narrow bitmap renders were inspected separately from actual compositor captures. The source journals and worktree files remained unchanged.

The first actual app replay found floating interval range marks and a table that selected rows without bringing them into view. The interval renderer now uses zero-based rectangles, and a native NSTableView adapter applies shared selection after layout, reveals a changed selection and preserves an unchanged reading position during data refreshes. Missing timestamps are shown as unavailable in the list and excluded from the timeline axis, rather than stretching it to a sentinel calendar date.

```sh
python3 scripts/create-curves-corpus-v77.py --output /private/tmp/lens-curves-corpus --events 600
zsh scripts/verify-design-v07.sh --source-root "$PWD" --output /private/tmp/lens-curves-check --corpus /private/tmp/lens-curves-corpus --entrypoint SessionCurvesV77Main.swift --after-source-freeze --run
bash scripts/test.sh -c release -Xswiftc -g --jobs 3
```

Native probe PNGs are bitmap-cache renders of production views, not compositor screenshots. Physical trackpad input, VoiceOver, and real collector throughput need separate qualification. No CPU, memory or latency improvement is claimed from compilation or passing tests.
