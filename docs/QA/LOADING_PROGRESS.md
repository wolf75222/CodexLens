# Loading progress

Loading uses native horizontal bars immediately. There is no delayed spinner or
SwiftUI timer that invents completion from elapsed time.

- Session discovery shows found files until a catalogue total exists. Catalogue
  metadata, finalization, history, action linking and index writing remain
  separate phases. History counters include reused indexed byte ranges; they are
  processed history coverage, not physical disk I/O.
- History shows aggregate known bytes, the current file and remaining bytes.
  Newly discovered journals can increase the total. Missing size information
  leaves the bar indeterminate.
- Presentation and timeline preparation expose their actual index/filter/cache
  path and event counts where a loop can measure them. Synchronous factories
  expose phase boundaries rather than simulated internal progress.
- Conversation indexing, message preparation and JSON/Markdown writing have
  measured counters. Atomic destination commit is a distinct final stage.
- File search reports read files and already discovered queued directories.
  The queue may grow; neither a byte budget nor directory limits represent a
  known filesystem completion percentage.
- Small source, diff, image and other reads use compact indeterminate bars with
  operation labels. Recorded diff parsing cancels its detached worker when the
  owning read is cancelled.

Counters belong to the current phase. Stage counts are not time weights, and no
whole-operation duration or completion estimate is synthesized. Known errors,
partial coverage and user cancellation retain their existing meanings.

Progress is bounded before UI publication, and streams keep only their newest
value. Unobserved session refreshes skip progress accounting. Descendant
discovery visits the new owner batch, agent lookup reuses first-winner indexes,
and unfiltered conversation review reuses its existing message array.

Validation uses anonymous bounded fixtures for totals, growth, cache reuse,
phase order, cancellation, commit failure and source preservation. The native
loading fixture checks actual AppKit bars, remaining counters, operation reset,
Reduce Motion and cancellation through the owned window's accessibility API.
Its PNG captures are offscreen NSHostingView renders, not desktop screenshots.
No active user session is used to force these conditions.
