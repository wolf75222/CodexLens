# Changes overview validation

The Changes collection now has one presentation selector: **Files**, **Worktrees** or **Actions**. Files provides a PR-style overview scoped by worktree; Worktrees adds selectable activity lanes; Actions retains the individual trace list. Existing recorded diff readers, investigation actions and navigation remain shared.

## Data contracts

- Exact environment identifiers remain separate, even when paths or filenames resemble one another.
- File paths are grouped lexically within their environment. No current file read, arbitrary symlink resolution or Git operation is used to reconstruct historical activity.
- Requests and explicitly linked results count as one recorded activity, while each trace stays selectable.
- Filters apply to individual traces before aggregation. Unknown dates remain in the list; a first trace is not a worktree creation date.
- Recorded branch/reference fields are labels from the session data. The lane display establishes no Git ancestry, authorship or net historical patch.
- A current Git read is explicit. Comparison from a recorded commit validates its full immutable object ID and includes committed and uncommitted tracked changes. An invalid or unavailable reference is an error, never a fallback to HEAD. Untracked and excluded authentication files are outside the comparison.

## Native fixture

`Tests/NativeUI/ChangesOverviewMain.swift` creates its own anonymous repository, two worktrees and journals under a fresh private temporary output. It uses the production store/readers and records source hashes before and after inspection. No active user session is used to manufacture cases.

The native checks cover file grouping, request/result distinction, a success message without a captured diff, missing metadata/dates, selected traces retained through filtering, current two-file Git reads, reading tabs and Back/Forward, peer-window state, three adaptive layouts and a dense 1,200-operation scenario. Graph marks are capped at 160 bins per lane and every grouped operation remains accessible.

Images are AppKit `NSHostingView.cacheDisplay` component bitmaps, not macOS compositor screenshots. Programmatic store/AX checks do not qualify physical pointer gestures, VoiceOver or every supported OS version. Bounded view counts establish a resource budget, not a measured latency or RAM improvement.

Run the fixture through `scripts/verify-design-v07.sh` with `--entrypoint ChangesOverviewMain.swift`. Keep the output, source manifest and receipt together. CI runs the same fixture before packaging.
