# Memory and search qualification

Lens keeps original sources read-only. These changes reduce retained copies and
temporary allocations without removing recorded events, payloads, links or
historical references.

- Optional trace payloads share immutable storage; absent payloads use empty
  reference slots. Copy-on-write mutations retain value semantics and the
  existing JSON format.
- Presentation and origin inspection share the event lookup. Graph adjacency
  stores row positions into one link array instead of two more link copies.
- Session search keeps row positions for related-event lookup and releases
  temporary full-record decoding objects after each match check.
- File search enumerates a shallow directory within its remaining entry budget.
  A truncated listing reports partial coverage. The file browser retains its
  existing full-list API, and authentication, symlink, version and byte guards
  remain in place.
- Long histories start with visual following paused. Collection continues;
  explicit live follow publishes newer snapshots. This avoids automatically
  preparing another large generation while a person reads the existing one.

## Measurements

Two separate optimized Core processes used the same private frozen input:
32 journals, 1,627,864,742 bytes and 468,672 complete records, producing
391,417 normalized events. The inputs and source identities were checked before
each run. Counts, event/source digests and all reported projections matched.
Private conversations, paths, journals and raw profiling receipts are not
included in the repository.

| Measurement | Before | After |
| --- | ---: | ---: |
| Physical footprint after opening | 2.462 GB | 1.993 GB |
| Physical footprint after preparation | 4.665 GB | 3.649 GB |
| Whole-process peak physical footprint | 4.785 GB | 4.076 GB |
| Preparation time | 71.22 s | 23.79 s |

GB values use decimal bytes. Stage measurements use `TASK_VM_INFO`;
whole-process peaks use macOS `/usr/bin/time -l`. The after run used a memory
watchdog and a fresh application cache. The minimum system memory-free reading
was 73%; the watchdog did not stop the run.

These results qualify Core preparation on this input and Mac. They do not
establish a whole-app UI peak, a cold disk-cache comparison, a leak scan or
identical compression/thermal conditions. Resident memory is not interchangeable
with physical footprint. The remaining multi-GB cost is explicit; no claim of
universal low memory use is made.

An anonymous 200,000-trace allocation probe separately measured retained growth
from 308,150,488 to 53,280,816 bytes. This component result is not the app result.

## Method references

Apple recommends identifying retained allocations and testing memory behavior
with measured traces: [Detect and diagnose memory issues](https://developer.apple.com/videos/play/wwdc2021/10180/).
SwiftUI work should be inspected for expensive or unnecessary updates:
[Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/).
Immutable dictionary assignment can share copy-on-write storage:
[Swift Dictionary documentation](https://docs.swift.org/latest/documentation/swift/dictionary/).

No extra search dependency was added. Full-record substring search and its
historical validation semantics remain unchanged.
