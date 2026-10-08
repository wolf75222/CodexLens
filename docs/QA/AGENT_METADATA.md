# Agent information

Each agent row can show its recorded role, such as `explorer`, `worker` or a custom role. The information button, context menu and inspector open the same existing details panel. Recorded descriptions, configured model, reasoning effort, provider, task name, context-sharing request and Codex version appear when available. Search includes these attributes.

## Data boundaries

- Initial session metadata and current local thread-table attributes retain distinct sources. A thread's configured/latest model and reasoning effort are not per-request execution telemetry.
- Requested settings from a spawn call remain labelled **Requested**. They are associated with a child only through an explicit child identifier, the parent thread and matching call ID. A missing prompt does not erase independently recorded request settings; a nickname, task path or nearby timestamp cannot establish the link.
- Full tasks and initial instructions stay in their original events and are opened on demand. Source links preserve the captured version; an initial-header link must match the source identity and fingerprint, not just its filename.
- Missing descriptions and roles remain unavailable. A role named `explorer` can be overridden by a custom agent, so Lens does not synthesize its instructions or description from the name. Current agent configuration files do not establish historical instructions and are not read to fill gaps.
- The compact header cache keeps bounded, redacted allowlisted attributes, not prompts or instruction bodies. Header format 2 and event format 8 invalidate older entries that lack the new fields. Corruption, source changes, ownership exclusions and home/worktree identity retain the existing cache rules.

## Interfaces inspected

The installed PATH CLI reports **0.143.0**, while the CLI bundled with ChatGPT reports **0.160.1**. Their own `app-server generate-json-schema` command was used in private temporary directories, without starting a live server or sending a model request. Both schemas expose thread roles and nested subagent role metadata. The 0.160.1 schema describes thread model/effort as configuration rather than per-turn telemetry.

Read-only local shape checks found `agent_role`, `model`, `reasoning_effort`, `agent_nickname` and `agent_path` in the thread table, and roles in `source.subagent.thread_spawn`. Sampled spawn calls contained `agent_type`, task/message, model, effort and `fork_turns`; their nickname-only outputs lacked child UUIDs. These observations informed the adapter without exporting private prompt text. They do not claim complete protocol support for either CLI version.

The [official subagent documentation](https://learn.chatgpt.com/docs/agent-configuration/subagents) describes built-in roles and custom agent definitions; the [App Server documentation](https://learn.chatgpt.com/docs/app-server) explains generated version-specific schemas. Live inference and authentication compatibility remain outside this feature.

## Verification

Logical tests cover explicit and ambiguous links, recorded/requested conflicts, optional legacy decoding, supported stored schema shapes, cache invalidation, current SQLite data, redaction/excerpts, opaque tasks, original instruction access and home/worktree isolation. UI checks and captures must distinguish native bitmap-cache renders, actual Mac compositor output and physical input. No hook, agent decision or observed thread is modified by opening these details.
