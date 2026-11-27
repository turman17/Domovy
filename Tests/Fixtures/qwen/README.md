# Qwen Code fixture (0.28)

Qwen Code is not installed on the development Mac. The layout is read from `QwenLM/qwen-code` at
`09b8135e6929df2e7f6a5cee8e55c47980b5f92e` (CLI 0.28.3); see docs/research/agent_storage_formats.md, Q9.
All content is synthetic. Paths are relative to `packages/core/src/`.

| Fixture file | Source |
| --- | --- |
| `projects/-Users-dev-code-orbit-api/` (slug: every non-alphanumeric char becomes `-`) | `utils/paths.ts#L388-L392`, `config/storage.ts#L619-L623` |
| `chats/<uuid>.jsonl`, records `{uuid, parentUuid, sessionId, timestamp, type, provenance, cwd, version, message:{role, parts}}` | `services/chatRecordingService.ts#L1511-L1531`, `#L1819-L1849`, `#L2808-L2826`, `#L3275-L3306` |
| `system` record with `subtype: custom_title`, `systemPayload.customTitle` | `services/chatRecordingService.ts#L2305-L2318` |
| `<id>.title.json` `{version, displayName, source, updatedAt}` | `services/session-title-sidecar.ts#L25`, `#L109-L125` |
| `<id>.runtime.json`, `.pr.json`, `.ledger.jsonl` sidecars | `config/config.ts#L8233-L8246`, `services/sessionService.ts#L1210-L1217` |
| `chats/archive/` (archived session with its sidecars; `.runtime.json` stays in `chats/`) | `services/sessionService.ts#L1039-L1047`, `#L2198-L2310`, `#L4628-L4760` |
| `subagents/<id>/` | `agents/agent-transcript.ts#L66-L90` |
| `file-history/<id>/`, `resources/<id>/` | `services/sessionService.ts#L2019-L2023`, `utils/sessionStorageUtils.ts#L813-L821` |
| `session-organization.v1.json` (never edited) | `services/session-organization-service.ts#L97`, `#L260` |
| `sessions/4242.json` `{schemaVersion, pid, procStart, sessionId, cwd, …}` | `services/session-registry.ts#L188-L236`, `#L322` |
| `tmp/session-writer-locks/<id>.lock` `{schema_version, state, session_id, pid, …}` | `services/session-writer-lease.ts#L238-L300`, `#L1709-L1719` |
| `tmp/<sha256>/chats/` (legacy, not read by 0.28) | `services/sessionService.ts#L943` (stale comment only) |
| `settings.json`, `oauth_creds.json` (protected) | `config/storage.ts#L15-L24`, `#L205-L226` |
