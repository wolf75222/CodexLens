# Session-curve captures

These images are original native macOS window captures from four isolated Codex Lens QA builds, reviewed on October 6, 2026. All use the dedicated anonymous curve corpus. No personal session, account identity, live model answer or credential is shown.

All eight JPEGs were produced by CUA's native `App.getScreenshot` API. They were copied byte-for-byte after checking their SHA-256 hashes and 2960 × 1640 pixel dimensions against the capture receipts. They are compositor captures, not mockups, generated images or `NSHostingView` bitmap-cache renders. No cropping, retouching, recoloring or annotations were applied to the published JPEGs.

The app UI is French in these captures; this is a supported interface language. The fixture's timestamps and recorded contents are unchanged. English documentation describes the equivalent control labels.

## Build identity and scope

| Review | Identity | What it establishes |
| --- | --- | --- |
| Baseline | Executable UUID `12946FC2-09FB-3582-9770-DE86DE95A51D`; 108 source inputs matched its build receipt | Histogram orientation and offscreen values-row defects before their corrections; an exact baseline commit was not established |
| Rendering corrections | Commit `77322f2c31da0f4506c44268ccdfdeab8aa1d75f`; executable UUID `C044565C-164E-3B9D-9613-4D34FD42646D`; 109 source inputs matched its build receipt | Correct histogram rendering and late values-row reveal after keyboard selection or hiding/showing the values panel; the Back/remount defect remains visible |
| Navigation corrections | Frozen development source based on `77322f2` plus uncommitted source-scope and bucket-anchor corrections; executable UUID `69B9CA48-2C2A-3698-B72E-213DC8D3D74B`; 109 matching source inputs | Two controlled activity-to-chart returns reveal the selected late row; a reader/workspace/history return preserves that context |
| Selected-control appearance | Frozen source with those corrections and two presentation modifiers; UUID `7243AAE4-A26E-3CF0-B80B-5F224CC4C35E`; 109 matching source inputs | Dark filled controls with legible white labels and a shorter activity picker in light/dark appearances; visual check only, before the values-table row accent is harmonized |
| Final palette | Frozen dirty release-candidate source with the existing native row-selection component; UUID `4DF7E741-494C-300B-A944-186CA06B2B6D`; 109 matching source inputs | Actively selected pastel-violet values row with an edge marker, plus the dark violet selected controls, in light/dark appearances; visual check only |

The rendering-correction captures precede subsequent source-transition dispatch and Back/remount fixes. They do not qualify those fixes. The later captures belong to frozen dirty development builds, not clean-commit releases. The 41 native checks and two controlled Back cycles belong to UUID `69B9CA48`; they are not newly attributed to either later visual appearance build. The `7243AAE4` phase is retained as metadata only: its redundant light/dark images are superseded by the final-palette illustrations. Each published image retains its original source identity even after later code is committed or tested.

## Published images

| File | Description |
| --- | --- |
| [before-histogram.jpg](before-histogram.jpg) | Baseline tool-call interval marks float at their counts, including pills for empty intervals |
| [histogram-light.jpg](histogram-light.jpg) | The same metric and corpus render as columns rising from zero |
| [before-table-reveal.jpg](before-table-reveal.jpg) | Baseline chart selection is 14:00:13–14:00:14 while the table remains at the first rows |
| [cumulative-values-revealed.jpg](cumulative-values-revealed.jpg) | Corrected keyboard selection of 14:01:03–14:01:04 is highlighted and visible in the native values table |
| [back-table-limit-before-remount-fix.jpg](back-table-limit-before-remount-fix.jpg) | On the same corrected-render build, Back retains that late selection but returns the values-table viewport to its first rows |
| [back-values-revealed.jpg](back-values-revealed.jpg) | On the frozen navigation-correction build, the second controlled Back return keeps the same late period selected and visible in the values table |
| [selected-mcp-harmonized-dark.jpg](selected-mcp-harmonized-dark.jpg) | Final-palette dark appearance with the late MCP period, dark violet selectors and actively selected pastel-violet values row |
| [selected-mcp-harmonized-light.jpg](selected-mcp-harmonized-light.jpg) | The same final-palette state after choosing Light in General settings; the values row was activated again before capture |

The two chart-selection comparison images use different selected periods. Both reproduce selection beyond the initially visible rows; they are not an identical-frame comparison. The Back comparison uses the same 14:01:03–14:01:04 selected period. The histogram comparison uses the same tool metric, 28 dated items and one-second intervals.

## Capture boundaries

The GUI reviews used native accessibility actions and keyboard input. Selecting a physical chart mark was refused by the CUA service. Hardware pointer selection, trackpad gestures, VoiceOver, deliberate narrow-window resizing and split-divider dragging were not qualified. A supplementary General-settings dark check retained the selection on UUID `69B9CA48`; the final published light/dark appearance images have the later `4DF7E741` identity. Dark appearance was not replayed on the rendering-correction build.

Before the two controlled navigation cycles, an isolated unexpected switch from Charts to the initial chronology was observed. Its cause is unknown; the initial reset itself was not captured in a JPEG. It did not recur in those two cycles. The published successful return does not establish that this unexplained observation was corrected. Full native window-count inventory was unavailable in that run.

No recorded command, AI request, login or external-resource action was performed. The GUI launch did not establish an OS network-denial guarantee. A collector status label in a screenshot does not measure live collector throughput. Source-transition dispatch was a separate code-review finding, not a reproduced source switch in these GUI runs. Visual label inspection does not establish a measured contrast ratio.

The separately generated native light/dark/narrow bitmap-cache renders are not included here. A raw crop used to check a suspected header overflow is also excluded: it rejected that suspicion and is not an original compositor screenshot.

[capture-manifest.json](capture-manifest.json) records relative filenames, hashes, byte counts, dimensions, source identities and review limits. Public metadata excludes machine-specific bundle paths, process IDs, local user paths and raw accessibility dumps. See the [curve audit](../../QA/SESSION_CURVES.md) for the correction and verification history.
