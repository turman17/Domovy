# Kiro fixture

Kiro is closed source and not installed on the development Mac; see docs/research/agent_storage_formats.md, Q9.
The sources disagree, so Domovy keeps Kiro read-only. All content is synthetic.

| Fixture file | Source |
| --- | --- |
| CLI 3.0 `~/.kiro/sessions/<workspace hash>/sess_<id>/session.json` (`title`, `workspacePaths`, `modelId`), `messages.jsonl` | third party, https://pypi.org/project/kiro-cli-history/ |
| CLI 2.x `~/.kiro/sessions/cli/<id>.jsonl` plus `<id>.json` | same |
| Kiro's docs: "SQLite database in ~/.kiro/", `kiro-cli chat --delete-session <ID>` | https://kiro.dev/docs/cli/chat/session-management/ |
| `~/.kiro/settings/mcp.json` | https://kiro.dev/docs/cli/mcp/configuration/ |
