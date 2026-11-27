# Changelog

All notable changes to Domovy. Versions follow [Semantic Versioning](https://semver.org).

## [1.0.0] - 2026-11-27

The first public release.

### Sessions
- One table of every agent session on the Mac: title, agent, project, last active, size and status (live, idle, archived, expiring), with search, filters and a native transcript preview.
- Proper delete: a session goes together with its companion files and index entries (Claude Desktop registry, Codex SQLite indexes, Cursor and Zed database rows, VS Code chat lists). Every delete is previewed as a plan and goes to the Trash or the Domovy quarantine, with undo.
- Archive with APFS transparent compression; agents can still resume archived sessions.
- Retention warnings before Claude Code, Gemini CLI or Antigravity delete history on their own, with Archive all.
- Secret scan of transcripts, on this Mac only, with redaction.
- Orphan finder: companion folders without a transcript, dangling registry entries, duplicates.
- Rules: optional scheduled tidying, always previewed.

### Disk and processes
- Per-agent disk breakdown, each category marked safe to remove, removable with consequences, or keep, with a one-line explanation.
- Guided cleanups: Claude Desktop VM bundle, large Codex rollouts, merged agent worktrees, leftover checkouts, Ollama, LM Studio and Hugging Face models.
- Processes: per-session memory and CPU, orphaned agent processes and MCP servers, freeze and resume. Herdr workspaces and panes are recognized.

### Agents
- Verified on a real install: Claude Code, Claude Desktop, Codex (CLI and app), Gemini CLI, Antigravity CLI, OpenCode, Cursor, Zed, VS Code chat, Gemini Code Assist, Herdr, Ollama, Hugging Face.
- Experimental (built from docs and source, marked in the app, CLI and MCP): Copilot CLI, Qwen Code, Kimi CLI, Roo Code, Cline, Kilo Code, Crush, Continue, Auggie, Factory Droid, Aider, Grok CLI; read-only Kiro, Goose, Amazon Q CLI; disk only Windsurf, Trae, Warp, Amp, Junie, iFlow CLI; LM Studio.

### CLI and agent integration
- `domo` CLI with the same engine: `ls`, `search`, `du`, `rm`, `archive`, `undo`, `clean`, `orphans`, `secrets`, `redact`, `ps`, `freeze`, `rules` and more; `--json` and `--dry-run` everywhere it matters; `domo --version`.
- `domo mcp`: an MCP server so agents can list and plan; changes run only with the token of a plan the user saw.
- `domo install` / `connect` / `disconnect`: registers the server and installs the `domovy` skill for every detected agent, and removes exactly that again.

### App
- Native SwiftUI app with a menu bar item, a first-run welcome and tour, Settings, keyboard shortcuts and full VoiceOver labels.
- No network, no telemetry. Nothing is deleted permanently by default.
