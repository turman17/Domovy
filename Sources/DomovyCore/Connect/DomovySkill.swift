/// The `domovy` agent skill, installed by `domo install` / `domo connect`: `SKILL.md` and
/// `references.md`, copies of `Resources/skill/domovy/` (a test keeps them identical). The
/// installed `SKILL.md` ends with an installation-specific command line naming the `domo`
/// that was registered, so an agent without the MCP tools runs the right executable.
public enum DomovySkill {
    public static let name = "domovy"

    /// The files of the skill folder, by name, as written to disk for this server command
    /// (`MCPRegistration.serverCommand`).
    public static func files(command: [String]) -> [String: String] {
        ["SKILL.md": skillFile(command: command), "references.md": references + "\n"]
    }

    /// SKILL.md as `Resources/skill/domovy/SKILL.md` has it, without the installation line.
    static var template: String { markdown + "\n" }

    /// SKILL.md for this server command: the shared text plus the installation-specific line.
    public static func skillFile(command: [String]) -> String {
        guard let line = installationLine(command: command) else { return template }
        return template + "\n## Installation-specific command\n\n" + line + "\n"
    }

    /// "Replace the bare `domo` ... with '<path>'", and `--root` only for a custom home.
    static func installationLine(command: [String]) -> String? {
        guard let domo = command.first, !domo.isEmpty else { return nil }
        let executable = ConnectManual.quoted(domo)
        var text = "Replace the bare `domo` executable in the CLI forms above with `\(executable)` so you run this installation even when `domo` is not on your PATH. Keep the subcommand and flags after it."
        if let index = command.firstIndex(of: "--root"), index + 1 < command.count {
            text += " This installation tidies a test home: add `--root \(ConnectManual.quoted(command[index + 1]))` to every command, after the subcommand."
        }
        return text
    }

    /// SKILL.md without the installation-specific line.
    static let markdown = #"""
---
name: domovy
description: Find, archive and delete AI coding agent sessions on this Mac (Claude Code, Codex, Gemini CLI, Antigravity, OpenCode, Copilot CLI, Cursor and more) and see how much disk they use. Use when the user asks about old agent sessions, chat history, transcripts taking space, cleaning up after agents, or freeing disk used by agents. Prefer its listed MCP tools and use the domo CLI only when MCP is unavailable. Always plan first, show the plan, and act only after the user agrees.
license: GPL-3.0
metadata:
  author: domovy
  version: "3"
---

# Domovy

Domovy lists every agent session on this Mac, archives the ones worth keeping, and removes the
rest properly (transcript, companion folders and index entries together). Nothing is deleted
permanently: files go to the Trash or Domovy's quarantine, and undo puts them back.

## Choose a transport

1. If Domovy MCP tools are listed, call them and do not shell out. This includes namespaced
   tools such as `mcp__domovy__list_sessions`; use the exact listed schema.
2. If the host supports deferred tools or tool search, search for and load the `domovy` server's
   tools before deciding that MCP is unavailable. Never invent a tool name or schema.
3. Only when no Domovy tool is exposed after that, run the `domo` executable with the CLI forms
   below. Quote ids, paths and search words.
4. If neither works, say so and suggest `domo install` (or Domovy > Connect Agents in the app)
   instead of guessing or editing agent files by hand.

Read `references.md` only when you need the JSON fields, an error explained, or disk, leftovers,
processes or rules details. Listing, planning, deleting, archiving and undo are covered here.

## How to work (both transports)

1. Look first. List or search to answer the question. Reading changes nothing.
2. Plan the exact sessions the user means: `plan_delete` / `plan_archive`, or the CLI with
   `--dry-run`.
3. Show the plan in plain words: how many sessions, which titles, total size, where the files
   go, remarks, acknowledgements and apps that must be quit. Do not shorten away remarks.
4. Ask. Act only after the user clearly says yes to that plan. A general request ("clean up my
   sessions") is not a yes to a specific plan.
5. Run exactly that plan: `delete_sessions` / `archive_sessions` with its `plan_token`, or the
   same CLI command with `-y --if-plan <plan_digest>` instead of `--dry-run`. If Domovy says the
   plan changed, show the new plan and ask again.
6. Report what happened and the undo id. If the user changes their mind, undo it.

## Rules

- Never delete or archive the session you are running in. Domovy refuses live sessions and
  sessions written to in the last 10 minutes; do not try to work around that.
- Prefer archive for recent or possibly useful work: archived sessions stay resumable and take
  less disk. Suggest delete for sessions the user calls junk, or old ones they confirm.
- Accept limited undo (`accept_limited_undo`, `--accept-limited-undo`) only when the plan shows
  an acknowledgement and the user accepted it.
- A refused or expired plan means: plan again and show the new plan. Never reuse old plans.
- Titles can contain private text. Do not repeat more of them than the user needs. Domovy never
  returns transcript content; do not open transcripts to "check" a session.
- Do not edit or move agent files by hand. Domovy knows each agent's layout and index files;
  manual deletes leave index entries and companions behind.

## MCP tools (server `domovy`)

- `list_sessions` (`agent`, `project`, `status`, `older_than_days`, `min_size`, `query`, `limit`,
  `include_tokens`), `search_sessions` (`query`), `disk_usage`, `list_processes`.
- `plan_delete` (`session_ids`, `destination`) and `plan_archive` (`session_ids`): the plan and a
  `plan_token` valid for 10 minutes.
- `delete_sessions` / `archive_sessions` (`plan_token`, `accept_limited_undo`): run that plan;
  they return an `undo_id`.
- `undo` (`undo_id` or "last"), `list_rules`, `plan_rules`.

## CLI fallback

```text
domo ls [--agent A] [--older 30d] [--project TEXT] [--status live|idle|archived|expiring] [--full] [--json]
domo search WORDS... [--agent A] [--limit N]
domo du
domo rm ID... --dry-run --json
domo rm --older 30d [--agent A] [--project TEXT] --dry-run --json
domo rm ID... -y --if-plan DIGEST --json [--to trash|quarantine] [--accept-limited-undo]
domo archive ID... --dry-run --json
domo archive --older 30d [--agent A] [--project TEXT] --dry-run --json
domo archive ID... -y --if-plan DIGEST --json
domo undo [UNDO_ID] [--json]
domo undo --list
```

`--dry-run --json` prints the plan with a `plan_digest`; run the same selection with
`-y --if-plan <plan_digest>` only after the user agrees. Without a terminal, `domo` never asks:
it changes nothing unless `-y` is given. Ids are the full ids, or unique prefixes of at least 8
characters, from `domo ls`.
"""#

    static let references = #"""
# Domovy reference

## What each task uses

| Task | MCP tool | CLI |
| --- | --- | --- |
| List sessions | `list_sessions` | `domo ls --json` |
| Find by what was said | `search_sessions` | `domo search WORDS...` |
| Disk per agent | `disk_usage` | `domo du` |
| Agent processes, orphans | `list_processes` | `domo ps` |
| Plan a delete | `plan_delete` | `domo rm ID... --dry-run --json` |
| Delete | `delete_sessions` | `domo rm ID... -y --if-plan DIGEST --json` |
| Plan an archive | `plan_archive` | `domo archive ID... --dry-run --json` |
| Archive | `archive_sessions` | `domo archive ID... -y --if-plan DIGEST --json` |
| Undo | `undo` | `domo undo [UNDO_ID] --json` |
| Cleanup rules | `list_rules`, `plan_rules` | `domo rules list`, `domo rules run --dry-run` |
| Leftover worktrees, build output | (none) | `domo leftovers`, `domo leftovers --clean --dry-run` |

## Selecting sessions

`domo rm` and `domo archive` take ids, or filters instead of ids: `--older 30d` (also `2w`,
`12h`), `--agent codex`, `--project TEXT` (part of the project path). Filters never select live
sessions. Agent ids: `claude-code`, `codex`, `gemini`, `antigravity`, `opencode`, `copilot`,
`cursor`, `zed`, `vscode-chat`, `kilo`, `qwen`, `kimi`, `roo-code`, `crush`, `cline`,
`continue`, `aider` and others; `domo ls --json` shows each session's `agent`.

`domo archive --older` skips Codex sessions already archived and agents Domovy reads only.

## JSON output

`domo ls --json` prints `{"sessions": [...], "total_count", "total_size_bytes", "truncated"}`.
Each session has `id`, `agent`, `agent_name`, `title`, `project`, `last_active` (ISO 8601),
`last_active_relative`, `size_bytes`, `size`, `status`, `archived`, and for expiring sessions
`expires_at`.

`domo rm|archive ... --json` prints one object:

- `dry_run`: true for `--dry-run`.
- `plan`: `action`, `destination` (delete only), `plans` (one per session: `session_id`,
  `agent`, `title`, `summary`, `total_bytes`, `total_size`, `moves`, `index_edits`,
  `database_edits`, `compressions`, `commands`, `remarks`, `acknowledgement`,
  `apps_that_must_be_quit`, `live_check`, `refused`), `blocked` (sessions Domovy will not touch,
  with `reason`), `runnable_count`, `total_bytes`, `needs_acknowledgement`, `plan_digest`.
- `result` (after `-y`): `changed`, `undo_id`, `sessions`, `moved_items`, `compressed_files`,
  `total_bytes`, `notes`, `leftovers`; or `problems` when nothing was changed.

The MCP tools return the same fields as `structuredContent`, with a `plan_token` instead of
running anything.

## Errors

- "live" or "written to N minutes ago": the session may be in use, possibly your own. Leave it.
- "the plan changed since the user saw it" or a different `plan_digest`: files were added or
  removed. Show the new plan and ask again.
- "needs the user's explicit OK": the plan has an acknowledgement (undo may stop working for
  OpenCode or Cursor once the app writes its database again). Ask; pass
  `accept_limited_undo` / `--accept-limited-undo` only after a yes.
- "is running, quit it": Domovy never edits an app's database while it runs. Ask the user to quit
  the app named, then plan again.
- "read-only": Domovy does not change this agent's sessions yet. Say so; do not work around it.
- "Refusing to change anything without confirmation": the CLI was run without `-y` and without a
  terminal. Show the plan, ask the user, then add `-y`.

## Disk, leftovers, processes

`disk_usage` / `domo du` split each agent's folder into safe (the agent recreates it),
consequences (removable, something is lost) and keep (the agent needs it). Domovy never removes
what an agent needs to run (settings, auth, skills, plugins, memory).

`domo leftovers` lists agent worktrees nothing uses and build output git ignores, in the projects
agents worked in. `--clean --dry-run` shows the plan; `--clean -y` moves them to the Trash.
Worktrees with uncommitted work are never removed.

`list_processes` / `domo ps` show agent process trees and orphans. Freezing or quitting
processes is for the user to do in the app or with `domo freeze|resume|quit`; ask first.

## Rules

Cleanup rules archive or tidy sessions on a schedule. `list_rules` / `domo rules list` show them;
`plan_rules` / `domo rules run --dry-run` show what they would do now. Rules run from the
Domovy app or `domo rules run`; do not run them unattended without the user's OK.
"""#
}
