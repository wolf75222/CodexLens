# Security and privacy

## Observation boundary

Codex Lens reads local persisted Codex records and accessible files. It does not resume observed threads, rerun their calls, install hooks, or edit observed repositories. File-system previews and fixed Git reads are distinct from any recorded historical version.

Lens writes its own cache, preferences, investigation archive, and explicitly selected exports. It does not collect telemetry or automatically download remote resources. Recognized authentication files, private keys, and sensitive paths are excluded from previews. Recognizable secrets in source text or selected context are redacted, but this does not detect every possible secret or personal detail.

## Investigation chat

The local Codex mode requires an installed, qualified Codex executable and a ChatGPT account. Codex manages its own credentials. Lens queries official account metadata without copying tokens or `auth.json` into its database. It does not silently fall back to an API key found in the environment.

Connection/model checks may use Codex's network access. Sending a question transmits its text, selected context, and conversation to OpenAI. Selection and preview alone do not send content. Review attached context before sending it.

The investigation runs in a separate thread with a verified permission profile. Observed repositories remain outside its write permissions; tool access to files and networking is restricted, and global hooks/connectors are disabled. Errors preserve the draft and do not automatically retry inference. Restriction checks fail closed for an unqualified Codex version or unverifiable configuration.

## Local and exported data

Investigation records are stored in `~/Library/Application Support/CodexLens/Investigations`; the observation cache is in `~/Library/Caches/CodexLens/Index-v1`. Both can contain sensitive source or conversation fragments. Budgeted local storage is not a confidentiality guarantee: protect your macOS account and backups.

Exports can contain conversation text, code, paths, IDs, and recorded instructions. Inspect an export before uploading it to an issue, chat, or public repository. File hashes establish content integrity, not trustworthiness or the identity of an exporter. Imported records are treated as data; their paths and commands are not executed.

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/wolf75222/CodexLens/security/advisories/new) when enabled. Include the app version, macOS version, a minimal anonymous reproduction, and the affected boundary.

Do not put credentials, raw Codex sessions, account emails, or sensitive source code into a public issue. If private reporting is unavailable, open a public issue requesting a private reporting channel and include no exploit details or personal data.

Security fixes are maintained in the latest release; no long-term support branches are currently promised.
