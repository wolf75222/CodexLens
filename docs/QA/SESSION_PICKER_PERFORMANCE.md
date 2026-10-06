# Session-picker loading

## What changed

The catalogue previously reopened and decoded every first `session_meta` record for each refresh, root opening and changed-source poll. `Data.firstIndex` scanning, file attributes, hexadecimal formatting and repeated redaction compilation dominated the measured catalogue work. SQLite was a small share.

Lens now keeps compact, immutable raw header fields and their source references in an optional private cache. It does not cache instructions, messages or full histories in this namespace. Every hit requires the current file identity, size, nanosecond modification/change times, mode and cloud flags. Directory membership, SQLite/WAL data, titles and investigation ownership are read afresh. Database fallback parentage is merged into a new object, so removed edges cannot stick to a cached header. A checksummed binary property list detects accidental corruption; invalid or unwritable caches fall back to the sources.

The retained-field estimate and persistent namespace each have an **8 MiB** budget, with eviction and pruning. This is an explicit cache budget, not a measurement of the application's entire heap. The existing event cache remains separate. Newline scanning uses a bounded per-chunk `memchr`; large Foundation JSON objects are released per file. Hash output and redaction results keep their previous values.

Overlapping catalogue requests share a reader-owned operation. Cancelling one waiter does not cancel its peers; closing or quiescing a reader drains its active and retiring operations. A startup restoration uses the main window instead of blocking the picker. Open Session cancels an in-flight Lens read and preserves an explicit choice made during startup. This never resumes or interrupts the observed Codex process.

Static signposts cover `SessionCatalog`, `CatalogDatabase`, `CatalogEnumeration`, `CatalogHeaders`, `CatalogTitles` and `CatalogPublish`; paths and recorded content are excluded.

## Measured engine comparison

Host: arm64, macOS 26.5, Xcode 26.6/SDK 26.5, Swift 6.3.3, 8 CPUs, 16 GiB RAM. Background load existed. The baseline is source `5c5b93c`; the after capture uses frozen dirty performance sources based on that revision. The unchanged Release harness and the original anonymous fixtures were used for both runs. All 45 comparison calls and 15 persisted-cache restart calls returned identical complete-summary hashes and counts. The same 12,510 fixture input files were reverified.

| Anonymous catalogue | Baseline warm median | After warm median | After fresh actor, empty Lens cache | After persisted-cache restart |
| --- | ---: | ---: | ---: | ---: |
| 500 sessions, about 23 KiB per first record | 196.9 ms | 23.9 ms | 104.6 ms | 36.5 ms |
| 1,000 sessions, about 1.5 KiB | 259.6 ms | 45.2 ms | 144.4 ms | 70.6 ms |
| 5,000 sessions, about 1.5 KiB | 1,295.7 ms | 218.7 ms | 709.5 ms | 342.2 ms |
| 1,000 sessions, about 131 KiB | 1,800.0 ms | 44.5 ms | 558.9 ms | 68.3 ms |
| 5,000 sessions, about 131 KiB | 11,234.6 ms | 216.8 ms | 4,470.2 ms | 342.1 ms |

Warm medians use five calls; fresh and persisted-cache medians use three. OS caches were not flushed. The baseline first actor's uncontrolled-OS-cache time for the representative fixture was 297.3 ms; the after first actor was 228.7 ms. These are engine measurements, not complete application launch or first-frame latencies. Loading a full selected history is a separate operation.

In the largest synthetic fixture, peak process RSS including the harness fell from 2,437.9 MB to 94.6 MB. This does not establish overall app memory use, heap allocation totals or absence of leaks. Persisted metadata occupied about 232 KiB for 500 sessions and 2.3 MiB for 5,000; the files used mode 0600.

Both bounded Instruments attachment attempts failed. No Time Profiler or Allocations trace is presented as successful. A successful 20-second `sample` of the owned baseline process attributed 56.6% of catalogue samples to first-record work, 15.6% to attributes and 14.8% to redaction. A separate after sample put all 11,271 catalogue samples on cooperative worker threads; the main thread waited in its run loop. This CLI executor result does not qualify SwiftUI responsiveness. Equivalent phase microprobes were retained separately and were not summed into catalogue latency.

## Reproduce and validate

Build with `bash scripts/build.sh --profile`. Run the anonymous replay tool with a new private output directory:

```sh
python3 scripts/measure-session-catalog.py --output /private/tmp/lens-catalog-replay
```

The tool records commands, toolchain, source/build/harness identities, fixture hashes, wall/CPU timings and process RSS. Its source-freeze assumption must be respected: built Core objects must correspond to the source being evaluated. No model request, personal-session read or OS cache flush is involved.

Run `bash scripts/test.sh -c release` for cache invalidation, ownership, home/worktree identity, DB/WAL/title changes, corruption, budgets, concurrent callers, cancellation and draining. The native picker probe separately checks store transitions and owned AppKit renderings; those bitmap caches are not compositor screenshots. Physical interaction and VoiceOver remain separate qualification. macOS 14 runtime, Intel, overall launch latency and an Instruments allocation/leak profile are unqualified by these measurements.
