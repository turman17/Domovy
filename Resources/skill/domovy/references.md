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
