# Factory Droid fixture

Factory Droid is closed source and not installed on the development Mac; see
docs/research/agent_storage_formats.md, Q9. All content is synthetic.

| Fixture file | Source |
| --- | --- |
| `~/.factory/sessions/<cwd with / as ->/<uuid>.jsonl` and `<uuid>.settings.json` | Factory's own skill, factory-ai/factory-plugins@`8f9ff2320aa254db98960c80002ab5f9988cc933^`, `plugins/core/skills/session-navigation/SKILL.md#L17-L36`, `#L88-L98`, `#L118` |
| first line `{type: session_start, id, title, cwd}`, then `{type: message, message: {role, content: [text, thinking, tool_use, ...]}}` | sageox/ox v0.26.0 `cmd/ox-adapter-droid` (third party, "confirmed against a real droid 0.126.0 install"), https://pkg.go.dev/github.com/sageox/ox/cmd/ox-adapter-droid |
| `settings.json`, `mcp.json` (protected) | https://docs.factory.ai/cli/configuration/mcp |

Not verified: whether any other per-session file exists, and how cloud session sync reacts to a local delete.
The assistant text is padded so the transcript is large enough to compress.
