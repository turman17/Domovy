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
