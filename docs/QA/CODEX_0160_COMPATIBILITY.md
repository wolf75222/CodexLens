# Codex 0.160.1 qualification

The installed desktop binary reported 0.160.1 while Lens previously accepted only 0.159.2. The release adapter now accepts those two exact versions and reports the version of the executable actually selected. Neighbouring, prerelease and malformed versions remain refused; this is not a general promise of compatibility with newer Codex binaries.

## Protocol and process boundaries

The [official App Server documentation](https://learn.chatgpt.com/docs/app-server) describes generating JSON schemas from the executable being integrated. All 440 generated experimental schema files matched across the official 0.159.2 release, official 0.160.1 release and both installed desktop executables. The inspected request/notification subset includes initialization, account/model/limit reads, thread and turn operations, approvals, configuration requirements and permission profiles.

Configuration and filesystem probes used disposable workspaces and isolated state homes. They verified the same restrictions for each qualified binary: MCP and hooks disabled, tools disabled in the control layer, a named restricted-read profile, denied writes and outside reads, and denied reads of host instructions. Authentication files remain Codex-owned. Lens does not acquire an API key or change the user's global configuration to obtain compatibility.

CI downloads the two official ARM64 releases with fixed SHA-256 hashes and runs the non-inference permission-profile tests. These tests require no account credentials or paid model request.

## Live check

A private qualification made exactly two small anonymous requests with the installed 0.160.1 executable, a ChatGPT connection and `gpt-6.1-sol`. Both completed with valid internal citations. The second request followed an engine restart and retained the same owned investigation thread and anonymous conversational marker. The existing Lens section and collector exclusion were verified. There was no automatic retry, API-provider fallback or action on an observed thread. The test processes were stopped; ownership metadata was retained so the test thread remains excluded from collection.

This qualifies those requests, not every model or account entitlement. Expired authentication, quota errors, interrupted streams and rejected approvals also have logical fixture coverage; no real account expiry or quota exhaustion was forced.

Private qualification receipts and raw generated schemas are not repository artifacts. Public tests and source describe the contracts without publishing account details or conversations.
