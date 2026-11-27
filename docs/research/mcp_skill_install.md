# Installing the Domovy MCP server and skill into agents

Checked 2026-11-23 against official vendor docs (and source code where docs were silent).
Server name `domovy`, command `/opt/homebrew/bin/domo mcp`. "Unverified" means no official
source confirmed it; re-check against a real install before relying on it.

## Agent Skills standard (agentskills.io)

Source: https://agentskills.io/specification

- Layout: `<skills-dir>/<name>/SKILL.md`, optional `scripts/`, `references/`, `assets/`.
- YAML frontmatter must open on line 1.
- `name` (required): 1-64 chars, `a-z`, `0-9`, `-` only; no leading/trailing hyphen, no `--`;
  must match the parent directory name.
- `description` (required): 1-1024 chars, says what the skill does and when to use it.
- Optional: `license`, `compatibility` (1-500 chars), `metadata` (string to string map),
  `allowed-tools` (space-separated, experimental).
- Body: no format rules; keep SKILL.md under 500 lines.

Writing a skill that meets the strict spec (lowercase hyphenated `name` = folder name,
description 1024 chars or less, only spec fields) is safe for every agent below. Agent-specific
fields (`disable-model-invocation`, `paths`, ...) get ignored or rejected depending on the agent.

## Claude Code

- MCP file: `~/.claude.json`, top-level `mcpServers` (user scope). Claude Code writes this file
  for itself all the time (account, project state, `/config`); the docs say you "don't need to
  edit it". Use the CLI, not file edits.
- Snippet (as stored):
  ```json
  { "mcpServers": { "domovy": { "type": "stdio", "command": "/opt/homebrew/bin/domo", "args": ["mcp"], "env": {} } } }
  ```
- CLI: `claude mcp add --transport stdio --scope user domovy -- /opt/homebrew/bin/domo mcp`
  and `claude mcp remove domovy --scope user`. `-s` is short for `--scope`. Options and the
  name go before `--`.
- Comments: no. Settings files are strict JSON; an unparseable `~/.claude.json` is a
  configuration error (backed up to `~/.claude/backups/`).
- Rewrites while running: yes (`~/.claude.json`).
- Skills: `~/.claude/skills/<name>/SKILL.md`. All frontmatter optional; `name` defaults to the
  folder; `description` + `when_to_use` truncated at 1536 chars in the listing. Many extra
  fields (`disable-model-invocation`, `allowed-tools`, `context`, `paths`, ...). Unknown fields
  are silently ignored.
- Sources: https://code.claude.com/docs/en/mcp, https://code.claude.com/docs/en/settings,
  https://code.claude.com/docs/en/skills (2026-11-23)

## Codex CLI (OpenAI)

- MCP file: `~/.codex/config.toml`, table `[mcp_servers.<name>]`.
- Snippet:
  ```toml
  [mcp_servers.domovy]
  command = "/opt/homebrew/bin/domo"
  args = ["mcp"]
  ```
- CLI: `codex mcp add domovy -- /opt/homebrew/bin/domo mcp` (`--env KEY=VALUE` repeatable),
  `codex mcp remove domovy` (no flags; user config only). Also `list`, `get`, `login`, `logout`.
  `enabled = false` disables without removing.
- Comments: yes (TOML). Whether `codex mcp add` preserves comments: unverified.
- Rewrites while running: unverified (Codex can write config on some UI actions).
- Skills: `~/.agents/skills/<name>/SKILL.md` (official). `~/.codex/skills` is not in current
  docs; legacy, unverified whether still read. Requires `name` and `description`; extra UI
  settings go in `agents/openai.yaml` beside SKILL.md, not frontmatter.
- Sources: https://learn.chatgpt.com/docs/extend/mcp?surface=cli,
  https://learn.chatgpt.com/docs/build-skills,
  https://github.com/openai/codex/blob/main/codex-rs/cli/src/mcp_cmd.rs (2026-11-23)

## Gemini CLI

Note: the docs say Antigravity CLI replaced Gemini CLI for the unpaid tier and Google One users
on 2026-06-18. Gemini CLI still exists for paid/API users.

- MCP file: `~/.gemini/settings.json`, top-level `mcpServers`.
- Snippet:
  ```json
  { "mcpServers": { "domovy": { "command": "/opt/homebrew/bin/domo", "args": ["mcp"] } } }
  ```
  Optional fields: `env`, `cwd`, `timeout`, `trust`, `includeTools`, `excludeTools`.
- CLI: `gemini mcp add -s user domovy /opt/homebrew/bin/domo mcp` and
  `gemini mcp remove -s user domovy`. Default scope is `project`, so always pass `-s user`.
- Comments: unverified (docs examples contain `//`, no explicit statement).
- Rewrites while running: unverified (the `/settings` dialog writes the file).
- Skills: `~/.gemini/skills/` or the alias `~/.agents/skills/` (the alias wins on conflict).
  `name` should match the folder; `description` required. CLI: `gemini skills install <url|path>
  [--scope user|workspace]`, `gemini skills uninstall <name> [--scope ...]`.
- Sources: https://geminicli.com/docs/tools/mcp-server/, https://geminicli.com/docs/cli/skills/,
  https://geminicli.com/docs/cli/creating-skills/, https://geminicli.com/docs/reference/configuration (2026-11-23)

## Qwen Code

- MCP file: `~/.qwen/settings.json`, top-level `mcpServers` (Gemini CLI fork, same shape).
- Snippet:
  ```json
  { "mcpServers": { "domovy": { "command": "/opt/homebrew/bin/domo", "args": ["mcp"] } } }
  ```
- CLI: `qwen mcp add -s user domovy /opt/homebrew/bin/domo mcp` (default scope is `user`,
  default transport `stdio`), `qwen mcp remove domovy` (no scope flag documented).
- Comments: unverified. Rewrites while running: unverified.
- Skills: `~/.qwen/skills/<name>/SKILL.md`; also reads `~/.agents/skills/` (`~/.qwen` wins).
  `name` regex `^[\p{L}\p{N}_:.-]+$` (looser than the spec), `description` required. Reads
  `allowedTools`, ignores `allowed-tools`.
- Sources: https://qwenlm.github.io/qwen-code-docs/en/users/features/mcp/,
  https://qwenlm.github.io/qwen-code-docs/en/users/features/skills/ (2026-11-23)

## Cursor

- MCP file: `~/.cursor/mcp.json`, top-level `mcpServers`.
- Snippet:
  ```json
  { "mcpServers": { "domovy": { "type": "stdio", "command": "/opt/homebrew/bin/domo", "args": ["mcp"] } } }
  ```
  The field table marks `type: "stdio"` as required; the doc examples omit it.
- CLI: none documented (UI, Marketplace, or `vscode.cursor.mcp.registerServer()` extension API).
- Comments: unverified. Rewrites while running: unverified (the UI toggles can write it).
- Skills: `~/.cursor/skills/` and `~/.agents/skills/`; for compatibility also loads
  `~/.claude/skills/` and `~/.codex/skills/`. `name` lowercase/digits/hyphens, must match the
  folder; `description` required; optional `paths`, `disable-model-invocation`, `icon`,
  `color`, `metadata`.
- Sources: https://cursor.com/docs/context/mcp, https://cursor.com/docs/context/skills (2026-11-23)

## OpenCode (sst/opencode)

- MCP file: `~/.config/opencode/opencode.json` or `opencode.jsonc`. Current docs use a nested
  `mcp.servers` object ("V2 does not place server names directly under `mcp`"). Whether the
  older `"mcp": { "<name>": {...} }` form is still accepted: unverified; check the schema at
  https://opencode.ai/config.json and the existing file before writing.
- Snippet (current docs):
  ```json
  { "$schema": "https://opencode.ai/config.json",
    "mcp": { "servers": { "domovy": { "type": "local", "command": ["/opt/homebrew/bin/domo", "mcp"] } } } }
  ```
  Env goes in `environment`; disable with `"disabled": true` (not `enabled`).
- CLI: `opencode mcp add --global domovy -- /opt/homebrew/bin/domo mcp` (`--env KEY=value`).
  No `remove` command; delete the entry from the config.
- Comments: yes, JSONC (comments and trailing commas) in both `.json` and `.jsonc`.
- Rewrites while running: unverified.
- Skills: `~/.config/opencode/skills/`, plus `~/.claude/skills/` and `~/.agents/skills/` for
  compatibility. The skill ID comes from the path; `name` is only a display label;
  `description` needed to advertise. Singular `skill/` is not in current docs (unverified).
- Sources: https://opencode.ai/docs/mcp-servers/, https://opencode.ai/docs/config/,
  https://opencode.ai/docs/skills/ (2026-11-23)

## GitHub Copilot CLI

- MCP file: `~/.copilot/mcp-config.json`, top-level `mcpServers`.
- Snippet:
  ```json
  { "mcpServers": { "domovy": { "type": "local", "command": "/opt/homebrew/bin/domo", "args": ["mcp"], "env": {}, "tools": ["*"] } } }
  ```
- CLI: `copilot mcp add domovy -- /opt/homebrew/bin/domo mcp`, `copilot mcp remove domovy`
  (user configuration). Also `list`, `get`, `enable`, `disable`.
- Comments: unverified. Rewrites while running: unverified.
- Skills: `~/.copilot/skills/` or `~/.agents/skills/`. `name` lowercase with hyphens,
  `description` required, optional `license`, `allowed-tools`.
- Sources: https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-mcp-servers,
  https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/create-skills (2026-11-23)

## Google Antigravity (app, IDE, CLI `agy`)

- MCP file: `~/.gemini/config/mcp_config.json` (global, shared by CLI and IDE per docs; this
  file exists on the dev machine). The older `~/.gemini/antigravity/mcp_config.json` comes only
  from third-party guides and is not on the dev machine; treat it as legacy. For the App, the
  docs say to use "Copy Config File Path" (the exact path is not documented).
- Snippet:
  ```json
  { "mcpServers": { "domovy": { "command": "/opt/homebrew/bin/domo", "args": ["mcp"] } } }
  ```
  Remote servers use `serverUrl` (legacy `url` / `httpUrl`).
- CLI: no add/remove documented; edit the file. `/mcp` opens the MCP manager overlay.
- Comments: unverified. Rewrites while running: unverified (the App has Add/Delete server UI).
- Skills: `~/.gemini/config/skills/<name>/SKILL.md` (App + CLI). The CLI also reads
  `~/.gemini/antigravity-cli/skills/` and `~/.gemini/skills/`; the App does not.
- Sources: https://antigravity.google/docs/mcp, https://antigravity.google/docs/customization-discovery/,
  https://antigravity.google/docs/cli/gcli-migration.md (2026-11-23)

## Claude Desktop

- MCP file: `~/Library/Application Support/Claude/claude_desktop_config.json`, top-level
  `mcpServers`.
- Snippet:
  ```json
  { "mcpServers": { "domovy": { "command": "/opt/homebrew/bin/domo", "args": ["mcp"] } } }
  ```
  Paths must be absolute. Quit and relaunch the app to load changes.
- CLI: none. Desktop Extensions (`.mcpb`) are the other install route.
- Comments: no (strict JSON, unverified but assume).
- Rewrites while running: unverified; the app is known to store its own keys (e.g.
  `preferences`) in this file, so read-modify-write and never write while it runs (safety rule 4).
- Skills: no local skills directory documented for Claude Desktop chat (skills are uploaded via
  claude.ai settings). Claude Code sessions inside Desktop use `~/.claude/skills/`.
- Sources: https://modelcontextprotocol.io/docs/develop/connect-local-servers (2026-11-23)

## Zed

- MCP file: `~/.config/zed/settings.json`, key `context_servers`.
- Snippet (docs shape):
  ```json
  { "context_servers": { "domovy": { "command": "/opt/homebrew/bin/domo", "args": ["mcp"], "env": {} } } }
  ```
  `"source": "custom"` is not in current docs or `assets/settings/default.json`; older Zed builds
  wrote it from the UI. Unverified whether it is still needed; harmless to match whatever entries
  already exist in the user's file.
- CLI: none; Settings > AI > MCP Servers > Add Local Server writes an entry to settings.json.
- Comments: yes in practice (Zed's own `default.json` and docs use `//`); not stated explicitly.
- Rewrites while running: yes, the settings UI and MCP UI edit settings.json in place; Zed
  watches and reloads it.
- Skills: `~/.agents/skills/<name>/SKILL.md` (direct children only). `name` per the spec
  (invalid names fail to load), `description` 1024 chars or less (longer loads with a warning),
  optional `disable-model-invocation`. Zed Agent only.
- Sources: https://zed.dev/docs/ai/mcp, https://zed.dev/docs/configuring-zed,
  https://zed.dev/docs/ai/skills,
  https://github.com/zed-industries/zed/blob/main/assets/settings/default.json (2026-11-23)

## VS Code (GitHub Copilot agent mode)

- MCP file: user profile `mcp.json`, opened by "MCP: Open User Configuration". On macOS
  this is `~/Library/Application Support/Code/User/mcp.json` for the default profile
  (path inferred from the profiles doc, unverified; other profiles live under
  `.../Code/User/profiles/<id>/`). Key `servers`.
- Snippet:
  ```json
  { "servers": { "domovy": { "type": "stdio", "command": "/opt/homebrew/bin/domo", "args": ["mcp"] } } }
  ```
  Optional top-level `inputs`, `sandbox`; per-server `cwd`, `env`, `envFile`.
- CLI: `code --add-mcp '{"name":"domovy","type":"stdio","command":"/opt/homebrew/bin/domo","args":["mcp"]}'`
  (adds to the user profile). No remove command documented; edit the file.
- Comments: unverified for mcp.json (VS Code settings files are JSONC; likely the same).
- Rewrites while running: VS Code edits the file from its MCP UI; unverified beyond that.
- Skills: `~/.copilot/skills/`, `~/.claude/skills/`, `~/.agents/skills/`. `name` lowercase,
  digits, hyphens, 64 max, matches folder (invalid names silently fail); `description` 1024 max;
  optional `argument-hint`, `user-invocable`, `disable-model-invocation`, `context`.
- Sources: https://code.visualstudio.com/docs/agents/reference/mcp-configuration,
  https://code.visualstudio.com/docs/configure/profiles,
  https://code.visualstudio.com/docs/copilot/customization/agent-skills (2026-11-23)

## Agents read from source (not installed on the development Mac)

Research date 2026-11-23, from the source clones of docs/research/agent_storage_formats.md, Q9.
None of this is verified on a real install. Skills for these agents: see "Skills per agent" below.

- **Kimi CLI** (`MoonshotAI/kimi-cli` @ `9ab1286b`): `~/.kimi/mcp.json` (`$KIMI_SHARE_DIR/mcp.json`),
  `{"mcpServers": {name: {command, args, env?}}}`. CLI: `kimi mcp add --transport stdio domovy --
  /opt/homebrew/bin/domo mcp`, `kimi mcp remove domovy`; no scope flag. —
  [cli/mcp.py#L10-L191](https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/cli/mcp.py#L10-L191)
- **Crush** (`charmbracelet/crush` @ `ee51fe87`): global config `~/.config/crush/crush.json`
  (`$CRUSH_GLOBAL_CONFIG`, `XDG_CONFIG_HOME`), key `mcp`, entry `{type: "stdio", command, args, env?,
  disabled?}`; `type` is required. No `crush mcp add` command. —
  [config.go#L197-L227](https://github.com/charmbracelet/crush/blob/ee51fe87bb306a945bf9057edf94f5574b192fd2/internal/config/config.go#L197-L227),
  [load.go#L1360-L1365](https://github.com/charmbracelet/crush/blob/ee51fe87bb306a945bf9057edf94f5574b192fd2/internal/config/load.go#L1360-L1365)
- **Cline** (`cline/cline` @ `34c104e6`): `~/.cline/data/settings/cline_mcp_settings.json`
  (`$CLINE_MCP_SETTINGS_PATH`, `CLINE_DATA_DIR`), `{"mcpServers": {name: {command, args?, env?, disabled?}}}`.
  The CLI has `cline mcp add <name> [--yes] -- <cmd>` and `cline mcp remove <name>`; Domovy edits the
  file instead because the flag order is not documented. —
  [paths.ts#L447-L453](https://github.com/cline/cline/blob/34c104e6fc49781cda4adcd73ffdccd8f029fef9/sdk/packages/shared/src/storage/paths.ts#L447-L453),
  [config-loader.ts#L60-L229](https://github.com/cline/cline/blob/34c104e6fc49781cda4adcd73ffdccd8f029fef9/sdk/packages/core/src/extensions/mcp/config-loader.ts#L60-L229),
  [apps/cli/src/main.ts#L473-L530](https://github.com/cline/cline/blob/34c104e6fc49781cda4adcd73ffdccd8f029fef9/apps/cli/src/main.ts#L473-L530)
- **Kilo Code** (`Kilo-Org/kilocode` @ `bfdec549`): the first of `kilo.jsonc`, `kilo.json`,
  `opencode.jsonc`, `opencode.json` in `~/.config/kilo` (`$KILO_CONFIG_DIR`), else `kilo.json`; key
  `mcp`, entry `{type: "local", command: [...], enabled: true}` like OpenCode. `kilo mcp add <name> --
  <cmd>` exists but there is no `kilo mcp remove`, so Domovy edits the file both ways. —
  [cli/cmd/mcp.ts#L396-L675](https://github.com/Kilo-Org/kilocode/blob/bfdec5496922452222223c01b4cc6c89305b0279/packages/opencode/src/cli/cmd/mcp.ts#L396-L675),
  [config/mcp.ts#L8-L60](https://github.com/Kilo-Org/kilocode/blob/bfdec5496922452222223c01b4cc6c89305b0279/packages/core/src/v1/config/mcp.ts#L8-L60)
- **Roo Code** (`RooCodeInc/Roo-Code` @ `b867ec91`): `<globalStorage>/rooveterinaryinc.roo-cline/settings/mcp_settings.json`,
  `{"mcpServers": {name: {type?, command, args?, env?, disabled?, alwaysAllow?}}}`; Roo watches the file.
  Domovy writes the VS Code copy only (`~/Library/Application Support/Code/User/globalStorage/…`); Roo in
  Cursor or VSCodium keeps its own. —
  [McpHub.ts#L67-L147](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/services/mcp/McpHub.ts#L67-L147),
  [#L487-L507](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/services/mcp/McpHub.ts#L487-L507)
- **Continue** (`continuedev/continue` @ `5522c6f4`): JSON files in `~/.continue/mcpServers/*.json` with
  the Claude Desktop shape `{"mcpServers": {...}}` are loaded next to YAML blocks and `config.yaml`
  `mcpServers:`. Domovy writes its own `~/.continue/mcpServers/domovy.json`, so `config.yaml` is never
  touched. The docs show only the workspace folder; the global folder is from the code. —
  [loadJsonMcpConfigs.ts#L24-L43](https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/context/mcp/json/loadJsonMcpConfigs.ts#L24-L43),
  [loadLocalAssistants.ts#L104-L125](https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/config/loadLocalAssistants.ts#L104-L125),
  [docs/customize/deep-dives/mcp.mdx#L27-L90](https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/docs/customize/deep-dives/mcp.mdx#L27-L90)

### Last batch (2026-11-23)

Same rules: none verified on a real install. Domovy edits the JSON file for all four connected agents.
Skills: see "Skills per agent" below.

- **Auggie** (`@augmentcode/auggie@1.2.2`, shipped bundle `auggie-v2.mjs`, build `6f24c7b3`): user settings
  `~/.augment/settings.json` (function `ykn`), key `mcpServers`, entry `{command, args}`; merged with project
  `.augment/settings.json` and `.augment/settings.local.json` (`iuo`). `auggie mcp add <name> -c <path> --args
  "<one string>"` and `auggie mcp add-json` exist; Domovy edits the file because `--args` takes the arguments as
  one string. — bundle help text of `auggie mcp add` / `add-json` / `remove`.
- **Factory Droid**: user `~/.factory/mcp.json`, `{"mcpServers": {name: {type: "stdio", command, args, env?,
  disabled?}}}`; Droid reloads the file when it changes. `droid mcp add <name> "<command>"` takes the command as
  one string, so Domovy edits the file. — [docs.factory.ai: MCP](https://docs.factory.ai/cli/configuration/mcp),
  [Factory-AI/factory@f0af3433 docs/cli/configuration/mcp.mdx](https://github.com/factory-ai/factory/blob/f0af3433/docs/cli/configuration/mcp.mdx?plain=1)
- **Kiro** (CLI and IDE share it): user `~/.kiro/settings/mcp.json`, `{"mcpServers": {name: {command, args?, env?,
  disabled?, autoApprove?}}}`, hot-reloaded. — [kiro.dev: MCP configuration](https://kiro.dev/docs/cli/mcp/configuration/)
- **Amazon Q CLI** (`aws/amazon-q-developer-cli` @ `15cc8f3c`): global `~/.aws/amazonq/mcp.json`
  (`MCP_CONFIG`), `{"mcpServers": {...}}`. `q mcp add` needs one flag per value. —
  [paths.rs#L59-L66](https://github.com/aws/amazon-q-developer-cli/blob/15cc8f3cd18c4272925ce1c7053268eedff1ea0a/crates/chat-cli/src/util/paths.rs#L59-L66)

Skipped, each for a reason:
- **Goose**: servers are `extensions:` in `~/.config/goose/config.yaml`. Domovy has no YAML editor that keeps
  every byte, and `goose configure` is interactive.
- **Windsurf**: Windsurf's MCP docs now describe Devin Local (`~/.config/devin/mcp_config.json`); the path for
  Windsurf itself (`~/.codeium/windsurf/mcp_config.json`, widely reported) is no longer documented there.
- **Amp**: the current manual does not document a user-level MCP config file or a stable `amp mcp add` form.
- **Warp**: MCP servers are configured in Warp's app and kept in its synced database.
- **Junie, Trae, iFlow, Grok CLI**: no documented user-level MCP config found (iFlow is discontinued).

## Takeaways for Domovy

- Prefer the agent CLI where it exists (Claude Code, Codex, Gemini, Qwen, Copilot CLI,
  OpenCode add, VS Code add) and verify afterwards with its `list`/`get`.
- File edits needed for: Cursor, Antigravity, Claude Desktop, Zed, and removal in OpenCode
  and VS Code. Back up first, preserve JSONC comments (OpenCode, Zed, likely VS Code), refuse
  while the app runs where it rewrites the file.
- One skill in `~/.agents/skills/domovy/` reaches Codex, Gemini CLI, Qwen Code, Cursor,
  OpenCode, Copilot CLI, Zed and VS Code. Claude Code needs `~/.claude/skills/domovy/`;
  Antigravity needs `~/.gemini/config/skills/domovy/`.

## What `domo connect` does with this (Sources/DomovyCore/Connect)

- Agent command when found on the real home: Claude Code, Codex, Gemini CLI (`-s user`), Qwen
  Code, Copilot CLI, Kimi CLI. File edits for Crush, Cline, Kilo Code, Roo Code (VS Code), Continue, Auggie,
  Factory Droid, Kiro and Amazon Q CLI. Afterwards Domovy reads the config to check that the entry is there. A
  custom home (`--root`, `DOMOVY_ROOT`) never runs agent CLIs. It always edits files.
- File edit for everything else, and as the fallback: one JSON(C) member inserted or removed, or
  one TOML table appended or removed. Comments, order and indentation stay as they were. The
  file is backed up to `<store>/Connect/Backups` first, and the edit is refused if the file
  changed since the plan. What was created (the file, parent objects, an empty object's
  whitespace, the exact TOML tail) is recorded in `<store>/Connect/connections.json`, so
  disconnect gives back the original bytes.
- Claude Desktop's config (and `~/.claude.json` when editing the file directly) is edited only
  while that app is quit.
- OpenCode: uses `mcp.servers` if the file already has it, otherwise flat `mcp.<name>` with
  `enabled: true`. The dev machine's file uses the flat form.
- Zed: adds `"source": "custom"` only when the user's other entries have it.
- Skills: one `SKILL.md` (Resources/skill/domovy/SKILL.md), written only into skills folders,
  per the table in "Skills per agent". The shared `~/.agents/skills` copy stays while any connected
  agent still reads it. Folders connect created (`~/.kimi/skills`, `~/.continue/mcpServers`, ...) are
  recorded and removed again on disconnect once empty. Agents that read both `~/.agents/skills` and
  `~/.claude/skills` see identical copies and pick one by precedence.
- Every step has a manual form (`ConnectStep.manual`): the agent's own command, the config snippet,
  or `mkdir -p <dir> && domo connect --print-skill > <dir>/SKILL.md`. The Connect sheet shows them
  with Copy buttons; `domo connect --dry-run` prints them.
- The `domo` registered: `DOMOVY_DOMO_PATH`, else the `domo` on PATH (Homebrew's, or Domovy's own
  link from "Install 'domo' Command in PATH", which goes to `~/.local/bin` or a writable
  `/usr/local/bin`), else `Domovy.app/Contents/Helpers/domo`, which the Xcode "Embed domo" phase
  (scripts/embed-domo.sh) builds into every app build.

## Skills per agent (checked 2026-11-24)

Rule: Domovy installs the skill only as its own folder `<skills-dir>/domovy/SKILL.md`. It never
appends to shared instruction files (CLAUDE.md, AGENTS.md, GEMINI.md, QWEN.md, .cursorrules,
global_rules.md, .goosehints), rules databases or settings fields, and it prefers skills (loaded on
demand) over always-on rules folders. Every agent below takes the Agent Skills format (`name` matching
the folder, `description`), so one file serves all.

| Agent | Skills folder Domovy writes | Why / source |
|---|---|---|
| Claude Code | `~/.claude/skills/domovy` | https://code.claude.com/docs/en/skills |
| Codex | `~/.agents/skills/domovy` | User scope is `$HOME/.agents/skills` (https://learn.chatgpt.com/docs/build-skills); `~/.codex/skills` is marked "Deprecated user skills location ... kept for backward compatibility" in openai/codex@f64f003 `ext/skills/src/host_roots.rs` |
| Gemini CLI | `~/.agents/skills/domovy` | `~/.agents/skills` alias of `~/.gemini/skills` (https://geminicli.com/docs/cli/skills/); no extension needed |
| Qwen Code | `~/.agents/skills/domovy` | https://qwenlm.github.io/qwen-code-docs/en/users/features/skills/ |
| Cursor | `~/.agents/skills/domovy` | https://cursor.com/docs/context/skills. User Rules live in the app (no folder): skipped |
| OpenCode | `~/.agents/skills/domovy` | "Global compatibility" list in https://opencode.ai/docs/skills/ |
| Copilot CLI | `~/.agents/skills/domovy` | https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/add-skills (`~/.copilot/instructions/*.instructions.md` is always-on: not used) |
| VS Code (Copilot) | `~/.agents/skills/domovy` | https://code.visualstudio.com/docs/copilot/customization/agent-skills |
| Zed | `~/.agents/skills/domovy` | https://zed.dev/docs/ai/skills. The Rules Library is a database: skipped |
| Crush | `~/.agents/skills/domovy` | Skills paths in https://github.com/charmbracelet/crush README |
| Kilo Code | `~/.agents/skills/domovy` | https://kilo.ai/docs/customize/skills. Global rules are the `instructions` array of kilo.jsonc (shared): skipped |
| Roo Code | `~/.agents/skills/domovy` | https://roocodeinc.github.io/Roo-Code/features/skills. `~/.roo/rules` is always on: skipped |
| Auggie | `~/.agents/skills/domovy` | https://docs.augmentcode.com/cli/skills. `~/.augment/rules` is always on: skipped |
| Factory Droid | `~/.agents/skills/domovy` | https://docs.factory.com/cli/configuration/skills |
| Antigravity | `~/.gemini/config/skills/domovy` | https://antigravity.google/docs/skills (App, CLI, IDE); `~/.agents/skills` not documented |
| Cline | `~/.cline/skills/domovy` | https://docs.cline.bot/customization/skills. `~/Documents/Cline/Rules` files are always on: not used |
| Continue | `~/.continue/skills/domovy` | continuedev/continue@5522c6f `core/config/markdown/loadMarkdownSkills.ts`, `extensions/cli/src/util/loadMarkdownSkills.ts` (global `~/.continue/skills`); does not read `~/.agents/skills` |
| Kiro | `~/.kiro/skills/domovy` | https://kiro.dev/docs/skills/ (the default agent loads them; the CLI table is ambiguous, unverified on a real install). Steering is not used |
| Kimi CLI | `~/.kimi/skills/domovy` | https://moonshotai.github.io/kimi-cli/en/customization/skills.html: the generic group takes only the first existing of `~/.config/agents/skills` and `~/.agents/skills`, so Kimi's own folder is the one that always loads |
| Claude Desktop | none | Chat skills are uploaded in claude.ai settings; no local folder |
| Amazon Q CLI | none | Replaced by Kiro CLI (Q CLI 1.20.0); its rules migrate to `~/.kiro/steering` (https://kiro.dev/docs/cli/migrating-from-q/) |

Not connect targets (no MCP config Domovy edits), noted for completeness: Goose reads `~/.agents/skills`
(https://goose-docs.ai/docs/guides/context-engineering/using-skills), so it gets the skill whenever another agent
installs the shared copy; Windsurf's global rules are one file (`global_rules.md`), skipped; Devin Desktop reads
`~/.agents/skills` (https://docs.devin.ai/desktop/cascade/skills).
