# Kimi CLI fixture

Kimi CLI is not installed on the development Mac. The layout is read from `MoonshotAI/kimi-cli` at
`9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82`; see docs/research/agent_storage_formats.md, Q9. All content
is synthetic. Paths are relative to `src/kimi_cli/`.

| Fixture file | Source |
| --- | --- |
| `kimi.json` `{work_dirs:[{path, kaos, last_session_id}]}` | `metadata.py#L17-L56` |
| `sessions/<md5(path)>/<uuid4>/` (md5 of the canonical path, no trailing slash) | `metadata.py#L33-L40`, `session.py#L145`, `packages/kaos/src/kaos/path.py#L82-L93` (repo root) |
| `state.json` (`version`, `custom_title`, `archived`, `archived_at`, …) | `session_state.py#L28-L43` |
| `context.jsonl` rows `{role, content, tool_calls?}`; `_system_prompt`, `_usage` rows | `soul/context.py#L99-L248`, `packages/kosong/src/kosong/message.py#L228-L269` (repo root) |
| `wire.jsonl` metadata line, then `{timestamp, message:{type: TurnBegin, payload:{user_input}}}` | `wire/file.py#L19-L37`, `session.py#L106-L128` |
| `subagents/<agent_id>/meta.json` | `subagents/store.py#L70-L123` |
| flat `sessions/<hash>/<id>.jsonl` (older versions, migrated by Kimi) | `session.py#L309-L318` |
| `config.toml`, `mcp.json`, `credentials/` (protected) | `config.py`, `cli/mcp.py#L10-L24`, `auth/oauth.py#L275-L309` |

The `_system_prompt` row is padded so the context file is large enough to compress.
