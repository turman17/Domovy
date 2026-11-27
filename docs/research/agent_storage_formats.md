# Agent session storage formats on macOS (late 2026): paths, registries, retention, safe deletion

Research date: 2026-11-22. All fetched content was treated as untrusted data. Raw outputs are saved in `/private/tmp/claude-501/-Users-yuriy-Documents-Github/cd66ee70-6623-4aae-b6ad-e19b2bded3ab/scratchpad/storage/`. The user's home directory was not read. "User report" means a GitHub issue or forum post, not vendor documentation.

## Q1. Exact paths, formats, session identity, and every artifact belonging to one session

### Takeaway
Each agent stores a "session" differently. Claude Code uses one JSONL file per session plus companion directories keyed by the same UUID. Codex uses one rollout JSONL (possibly `.jsonl.zst`) plus rows in SQLite DBs and a name index. Cursor IDE keeps sessions as rows in one large SQLite KV DB. Gemini CLI and Copilot CLI use per-session files under a project hash or session ID. OpenCode uses one SQLite DB. To delete a session completely, the app needs a separate adapter for each agent.

### Cited Findings

**Claude Code CLI (`~/.claude`, or `$CLAUDE_CONFIG_DIR`)**
- Transcript: `~/.claude/projects/<project>/<session-id>.jsonl`. `<project>` is the working-directory path with every non-alphanumeric character replaced by `-`. Names longer than 200 chars are truncated and a hash of the full path is appended. Each line is a JSON object (message, tool use or result, model request record, or metadata). The format is internal and changes between versions. — [Claude Code docs: sessions](https://code.claude.com/docs/en/sessions)
- Per-session artifacts, documented as removed together by the retention sweep:
  - `projects/<project>/<session>.jsonl`
  - set-aside copies `projects/<project>/<session>.orphaned-<timestamp>-<suffix>.jsonl` and `<session>.jsonl.superseded-<timestamp>`, which are not shown in the picker
  - `projects/<project>/<session>/subagents/`, which holds subagent transcripts and is removed with the parent
  - `projects/<project>/<session>/tool-results/`, which holds spilled large outputs and MCP images
  - `projects/<project>/<session>/mcp-tasks/`
  - `file-history/<session>/`, which holds checkpoint snapshots for the 100 most recent checkpoints
  - `image-cache/<session>/` (legacy, v2.1.274 and earlier)
  - `uploads/<session>/`
  - `dev-mods/<session>/`
  — [Claude Code docs: .claude directory](https://code.claude.com/docs/en/claude-directory)
- Not keyed per session but swept by age: `plans/`, `debug/` (per-session debug logs), `paste-cache/`, `session-env/` (per-session environment metadata), `tasks/` (one dir per task list), `shell-snapshots/` (removed on clean exit and swept after crashes), `backups/` (`~/.claude.json` copies, newest 5 kept), `usage-data/`, `feedback/drafts/`, `skills/.trash/`, `plugins/.trash/`, `plugins/mcpb/`. The docs call `todos/`, `statsig/` and `logs/` legacy: they are no longer written and the sweep removes them. — [claude-directory](https://code.claude.com/docs/en/claude-directory)
- Since v2.1.274, pasted and attached images live outside `~/.claude`, in a per-session `images/` dir under the temp directory. On macOS the session scratchpad is `/private/tmp/claude-<uid>/<project>/<session-id>/scratchpad/`. The retention sweep deletes the scratchpad with the transcript. `claude purge` does not touch it. — [claude-directory](https://code.claude.com/docs/en/claude-directory)
- Kept until the user deletes them:
  - `history.jsonl`: typed prompts with timestamp and project path. It is trimmed by age only under HIPAA configuration.
  - `stats-cache.json`
  - `cache/changelog.md`
  - `remote-settings.json` and `policy-limits.json`
  - `sessions/`: one small file per running session, removed on exit, so it works as a liveness hint.
  - State files to keep: `.credentials.json`, `agent-memory/`, `jobs/`, `daemon/`.
  - Auto memory at `projects/<project>/memory/`. The sweep does not delete it, so it must not be removed with a session.
  — [claude-directory](https://code.claude.com/docs/en/claude-directory)
- Background sessions (agent view): `~/.claude/daemon/roster.json` lists running background sessions. `~/.claude/jobs/<id>/state.json` holds per-session state, and `~/.claude/jobs/<id>/tmp/` is removed when the session is deleted. `~/.claude/daemon.log` is the supervisor log. — [Claude Code docs: agent view](https://code.claude.com/docs/en/agent-view)
- `~/.claude.json` holds app state and per-project entries. `claude purge` deletes "the project's entry in `~/.claude.json`". — [claude-directory](https://code.claude.com/docs/en/claude-directory)
- Worktrees: `--worktree <name>` creates `.claude/worktrees/<name>/` at the repo root on branch `worktree-<name>`. PR worktrees go to `.claude/worktrees/pr-<number>`. A WorktreeCreate hook can place them anywhere else. — [Claude Code docs: worktrees](https://code.claude.com/docs/en/worktrees)
- Sessions that run in a worktree get a separate project directory keyed to the worktree path. A user audit found 6 lost sessions "stored under a separate project directory keyed to the worktree path". — [anthropics/claude-code#99817](https://github.com/anthropics/claude-code/issues/99817)
- `/resume` labels come from `custom-title` records (written by `/rename`) and other record types. A third-party tool author reverse-engineered the label priority. — [#26904 comment](https://github.com/anthropics/claude-code/issues/26904)

**Claude Desktop (`~/Library/Application Support/Claude`)**
- Code-tab session registry: `~/Library/Application Support/Claude/claude-code-sessions/**/local_*.json`, one JSON per session. Fields reported by users include `title`, `cwd`, `completedTurns`, `model`, `isArchived` and `cliSessionId`. A Desktop "delete" removes only the `local_*.json`. The transcript `~/.claude/projects/<slug>/<session-id>.jsonl` and its `subagents/` and `tool-results/` folders stay on disk. — [anthropics/claude-code#89547](https://github.com/anthropics/claude-code/issues/89547); [#99817](https://github.com/anthropics/claude-code/issues/99817) (macOS path, `deleted_*` markers); [#73959](https://github.com/anthropics/claude-code/issues/73959) (`isArchived`, nested `<dir>/<dir>/local_<sessionId>.json`, and the app overwrites edits unless it is fully quit); [#99817 comment](https://github.com/anthropics/claude-code/issues/99817) (`cliSessionId`, `transcriptUnavailable`)
- Desktop deletions leave `deleted_*` marker files in the registry. One user's store had 4 of them among 97 records. — [#99817](https://github.com/anthropics/claude-code/issues/99817)
- When the user continues a conversation after a Desktop restart, the app writes a full re-stamped copy of the transcript under a new session id and leaves the old file unreferenced. One user found 23 of 79 orphaned transcripts were such copies, with 8 copies for one conversation. — [#89547 comment](https://github.com/anthropics/claude-code/issues/89547), [#89592](https://github.com/anthropics/claude-code/issues/89592)
- Cowork / local agent mode: `local-agent-mode-sessions/.../` holds per-session folders with `audit.jsonl` and `subagents`. `scheduled-tasks.json` (the scheduler index) lives inside `local-agent-mode-sessions`. — [#55418](https://github.com/anthropics/claude-code/issues/55418); [#93583](https://github.com/anthropics/claude-code/issues/93583) (Windows path, "Delete Cowork VM Sessions and Restart" wiped `scheduled-tasks.json` and all local chat transcripts)
- When a file is attached in Cowork, the app hard-links it into `local-agent-mode-sessions`. — [#82164](https://github.com/anthropics/claude-code/issues/82164) (title only)
- VM bundle: `~/Library/Application Support/Claude/vm_bundles/claudevm.bundle/` contains:
  - `rootfs.img`: the live raw disk, 10 GiB, fully allocated
  - `rootfs.img.zst`: the ~1.1-2 GB compressed base, kept after extraction
  - `sessiondata.img`: per-session state, 1.3-1.9 GB reported, 8.5 GB fixed size in one report, an encrypted "shdw" container
  - a `.sdk-version` file
  - a zero-byte `.partial` download artifact
  - also `vm_bundles/warm`
  — [#65577](https://github.com/anthropics/claude-code/issues/65577); [#89869](https://github.com/anthropics/claude-code/issues/89869); [#107097](https://github.com/anthropics/claude-code/issues/107097); [#55418](https://github.com/anthropics/claude-code/issues/55418); [#30751](https://github.com/anthropics/claude-code/issues/30751); [#75302 via search snippet](https://github.com/anthropics/claude-code/issues/75302); [#22543 comments](https://github.com/anthropics/claude-code/issues/22543)
- Inside the VM, each conversation creates `/sessions/<name>/` with plugin caches under `mnt/.skills`, `mnt/.remote-plugins/` and `mnt/.local-plugins/{cache,marketplaces}`. These are never cleaned up, and `sessiondata.img` fills after about 80 conversations. — [#30751](https://github.com/anthropics/claude-code/issues/30751)
- Electron data: `Cache/Cache_Data/`, `Code Cache`, `Local Storage/leveldb/` and `IndexedDB` hold UI state only, not message content. — [#55418](https://github.com/anthropics/claude-code/issues/55418); [#22543](https://github.com/anthropics/claude-code/issues/22543) (deleting `Cache` and `Code Cache` as a workaround)
- Verified on a real install (Claude Desktop 6.6395.0, bundle id `com.anthropic.claudefordesktop`, 2026-11-23; names, sizes, nesting and key schemas only, no values read):
  - Registry: `claude-code-sessions/<uuid>/<uuid>/local_<uuid>.json`, one file per session (0.5-22 KB). Both folder names are UUIDs; what they stand for (account, organization) is not established. Domovy treats any other place as an unknown layout and goes read-only.
  - Keys present in every entry: `sessionId` (string, `local_<uuid>`, equal to the file name), `cliSessionId` (string UUID, the transcript name `~/.claude/projects/<slug>/<cliSessionId>.jsonl`; differs from `sessionId`), `cwd`, `originCwd`, `title`, `titleSource`, `model`, `effort`, `permissionMode` (strings), `createdAt`, `lastActivityAt` (integer epoch milliseconds), `completedTurns` (int), `isArchived` (bool), `remoteMcpServersConfig`, `alwaysAllowedReasons` (lists).
  - Keys present in some entries: `lastFocusedAt`, `latestUserFrameAt`, `titleTurn` (ints), `priorCliSessionIds` (list of transcript UUIDs), `postTurnSummary`, `promptAppendSnapshot`, `toolSurfaceSnapshot`, `transcriptModelStates`, `spawnSeed` (objects), `rewindEdges`, `publishedArtifacts`, `sessionPermissionUpdates` (lists), several booleans (`classifierSummaryEnabled`, `remoteControlAutoEligible`, `steeredByRemoteClient`, ...). `transcriptUnavailable` was not present here.
  - `priorCliSessionIds` lists the earlier transcript ids of a conversation Desktop continued under a new id; on this install the one listed transcript still exists. This is the on-disk trace of the #89592 duplicates.
  - Deletion markers: `deleted_<uuid>` files without extension next to the entries, 13 bytes of digits (an epoch-millisecond timestamp, inferred). Their uuid matches no remaining entry and no transcript.
  - `scheduled-tasks.json` also sits in the same `<uuid>/<uuid>/` folder (keys `scheduledTasks`, `recordedSkips` and two booleans).
  - 3 of 7 entries pointed at a transcript that no longer exists (registry orphans). No two entries shared a `cliSessionId`.
  - Process names: the app runs as `Claude` with Electron helpers `Claude Helper (...)`; the Claude Code CLI runs as `claude` (lowercase), so the running-Desktop check is case-sensitive.
  - Assumed, not verified: that Desktop rewrites the registry from memory while running (#73959), so Domovy edits it only while Desktop is quit; that removing an entry file is all a Desktop "delete" does besides writing a `deleted_*` marker (Domovy does not write markers).

**Codex CLI and Codex app (`~/.codex`, or `$CODEX_HOME`; CLI and desktop app share it)**
- Rollouts: `~/.codex/sessions/YYYY/MM/DD/rollout-<timestamp>-<session-id>.jsonl`. The first line has `type: session_meta` with `id`, `cwd`, `cli_version`, `git`, `parent_thread_id` and other fields. Other line types are `response_item`, `event_msg`, `turn_context` and `compacted`. Observed on 0.166.0. — [Sealkeep: where Codex stores sessions](https://sealkeep.spala.ai/guides/where-codex-stores-sessions); [openai/codex#29531](https://github.com/openai/codex/issues/29531)
- Source constants: `SESSIONS_SUBDIR = "sessions"`, `ARCHIVED_SESSIONS_SUBDIR = "archived_sessions"`. — [codex-rs/rollout/src/lib.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/lib.rs)
- Compressed rollouts are named `<name>.jsonl.zst` (zstd level 3, only for rollouts older than 7 days, lock file `rollout-compression.lock`). The feature flag is `local_thread_store_compression`, stage "UnderDevelopment", `default_enabled: false`. Hard-delete removes both the plain and the `.zst` path. — [codex-rs/rollout/src/compression.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/compression.rs); [codex-rs/features/src/lib.rs](https://github.com/openai/codex/blob/main/codex-rs/features/src/lib.rs); [delete_thread.rs](https://github.com/openai/codex/blob/main/codex-rs/thread-store/src/local/delete_thread.rs)
- SQLite DBs, from source constants: `state_5.sqlite`, `logs_2.sqlite`, `goals_1.sqlite`, `memories_1.sqlite`, `memories_v2_1.sqlite`, `queue_1.sqlite`, `thread_history_1.sqlite`. Location is `sqlite_home`; logs go to `log_dir`. — [codex-rs/state/src/sqlite.rs](https://github.com/openai/codex/blob/main/codex-rs/state/src/sqlite.rs); [Codex config reference](https://developers.openai.com/codex/config-reference)
- `threads` table columns: `id` PK, `rollout_path`, `created_at`, `updated_at`, `source`, `cwd`, `title`, `archived`, `archived_at`, `git_*` and others. Related tables: `thread_spawn_edges(parent_thread_id, child_thread_id)` and `thread_attachments`, formerly `thread_artifacts`, with `ON DELETE CASCADE`. There are 64 migrations so far. — [migrations/0001_threads.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0001_threads.sql), [0021](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0021_thread_spawn_edges.sql), [0051](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0051_thread_artifacts.sql), [0055](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0055_thread_attachments.sql)
- `session_index.jsonl` is an append-only thread-name index; "the most recent entry wins". Rewrites are serialized with `session_index.jsonl.lock`. — [codex-rs/rollout/src/session_index.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/session_index.rs)
- `history.jsonl` holds prompt history, controlled by `history.persistence` (`save-all` or `none`) and `history.max_bytes`. Logs go to `$CODEX_HOME/log`. — [Codex config reference](https://developers.openai.com/codex/config-reference)
- Worktrees: `~/.codex/worktrees/<hex-id>/<project-name>/`, each with a `.git` gitdir pointer into `repo/.git/worktrees/<name>/`. — [iamquang95/codex-clean (search snippet)](https://github.com/iamquang95/codex-clean); [openai/codex#54891](https://github.com/openai/codex/issues/54891)
- Verified on a real install (codex-cli 0.169.0, app-server daemon 0.171.0, 2026-11-23; names, sizes, schemas and counts only):
  - Rollouts at `sessions/YYYY/MM/DD/`, most of them `.jsonl.zst` even though `codex features list` reports `local_thread_store_compression` as false. Thread ids are UUIDv7.
  - Some rollouts are named `rollout-<ts>-<thread>_<uuid>.jsonl[.zst]`; the second uuid has no `threads` row, so they are treated as further segments of `<thread>` (inferred).
  - `archived_sessions/` is flat; its file count matches `threads.archived = 1`.
  - `session_index.jsonl` keys: `id`, `thread_name`, `updated_at`. `history.jsonl` keys: `session_id`, `text`, `ts`.
  - `generated_images/<thread-id>/` is keyed by thread id. `attachments/<uuid>/` is not (no match to any rollout); it is indexed by `attachments/pasted-text-attachments.json`.
  - `thread-writer-locks/<thread-id>.lock`: the app-server daemon holds these open while a thread is loaded (lsof), and holds rollouts open too.
  - `state_5.sqlite` (64 migrations): `threads` has `title`, `cwd`, `rollout_path`, `archived`, `first_user_message`; thread-keyed tables also in `thread_history_1.sqlite`, `logs_2.sqlite`, `goals_1.sqlite`, `memories_1.sqlite`, `queue_1.sqlite`, `sqlite/codex.db`.
  - The CLI's own help lists `archive`, `unarchive`, `delete` (`--force`: SESSION must be a UUID). No `worktrees/` folder on this install.
  - A Codex process (the app-server daemon of the ChatGPT app) runs persistently.
- Per-run temporary repo copies were also reported in `/private/tmp`: 118 copies, 202 GB, not registered anywhere Codex can see. — [openai/codex#35383 (search snippet)](https://github.com/openai/codex/issues/35383)

**Cursor**
- Global DB: `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (SQLite) with tables `ItemTable` and `cursorDiskKV`. A newer `composerHeaders` table was also reported. Per-conversation keys:
  - `composerData:{composerId}`
  - `bubbleId:{composerId}:{bubbleId}`
  - `checkpointId:{composerId}:{checkpointId}`
  - `messageRequestContext:{composerId}:{messageId}`
  - content-addressed `composer.content.{hash}` blobs, shared across conversations
  - `agentKv:*` agent blobs
  — [cursaves: how Cursor stores chats](https://github.com/Callum-Ward/cursaves/blob/main/docs/how-cursor-stores-chats.md); [Cursor forum #167641](https://forum.cursor.com/t/state-vscdb-grows-to-30gb-due-to-bubbleid-agentkv-entries/167641)
- Since Cursor 3.0 (April 2026), the chat list index is `composer.composerHeaders` in the global `ItemTable`. Each entry has a `workspaceIdentifier` (an `id` matching the `workspaceStorage/<id>` hash, plus a `uri`). Per-workspace `workspaceStorage/<id>/state.vscdb` plus `workspace.json` now keep only selected tabs. — [cursaves](https://github.com/Callum-Ward/cursaves/blob/main/docs/how-cursor-stores-chats.md)
- Plain-text agent transcripts are written to `~/.cursor/projects/{sanitized-path}/agent-transcripts/{composerId}.txt`. They are read-only and supplementary; Cursor never loads them. — [cursaves](https://github.com/Callum-Ward/cursaves/blob/main/docs/how-cursor-stores-chats.md)
- Cursor CLI agent chats: `~/.cursor/chats/<workspace-hash>/<chat-uuid>/`. — [Cursor forum #156640](https://forum.cursor.com/t/cursor-agent-create-chat-and-how-to-delete-old-chats/156640)
- Worktrees: `~/.cursor/worktrees`. The location is not in Cursor's docs; `cursor.worktreeMaxCount` is the limit setting. — [luchasarie/agent-cleanup README](https://github.com/luchasarie/agent-cleanup); [gregkop/worktree-cleanup (snippet)](https://github.com/gregkop/worktree-cleanup)
- Verified on a real install (2026-11-23; Cursor.app itself is no longer installed here, its data last written 2026-01-21, so a pre-3.0 version; `state.vscdb` opened in place with `SQLITE_OPEN_READONLY` and `immutable=1`, never copied; table schemas, key counts per prefix, key shapes and JSON field names and types only; no values read):
  - `User/globalStorage/`: `state.vscdb` (4.9 MB, page size 4096), `state.vscdb.backup` (same size), `state.vscdb.options.json` (`useWAL` true; no `-wal` or `-shm` with Cursor quit), `storage.json`. `User/workspaceStorage/` is empty here.
  - Schema: `ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)` and `cursorDiskKV` (same). Values are stored as text JSON.
  - `cursorDiskKV` key shapes (553 rows): `bubbleId:<uuid>:<uuid>` 361, `checkpointId:<uuid>:<uuid>` 54, `composerData:<uuid>` 36, `codeBlockPartialInlineDiffFates:<uuid>:<uuid>` 36, `codeBlockDiff:<uuid>:<uuid>` 32, `messageRequestContext:<uuid>:<uuid>` 19 plus one `messageRequestContext:<uuid>:WARM_SUBMIT`, `inlineDiffs-<n>` 8, `inlineDiffs-<hex>` 4, `composer.autoAccept.*` 2. No `agentKv:` and no `composer.content.*` rows on this version. For every two-part prefix, the first uuid is a `composerData` id (100%), so those rows belong to one chat.
  - `composerData` JSON: `_v`, `composerId` (equals the key), `createdAt` (integer ms), `fullConversationHeadersOnly` (array of `{bubbleId, type, serverBubbleId?}`), `conversationMap`, `subComposerIds` (all empty here), `status`, `text`, `richText`, `context`, `modelConfig`, `usageData`, `isArchived`, `isDraft`, `unifiedMode`, … No `name` and no `lastUpdatedAt` on this version. 35 of 36 have an empty conversation (unused tabs); every header `bubbleId` has its `bubbleId:` row.
  - `bubbleId` JSON: `type` (1 user: 19, 2 assistant: 342), `text`, `richText`?, `createdAt` (ISO text), `bubbleId`, `requestId`, `toolResults`, `tokenCount`, … `checkpointId`: `files`, `nonExistentFiles`, `activeInlineDiffs`, …
  - `ItemTable` (167 rows) has no `composer.composerHeaders` (pre-3.0) and no `composer.composerData`; 13 `workbench.panel.composerChatViewPane.<uuid>.hidden` keys whose uuids are not chat ids (0 of 13), so they are panel ids, not chats. Sign-in keys (`cursorAuth/*`) sit in the same table, so the file is never copied for research.
  - `~/.cursor`: `ai-tracking`, `argv.json`, `cli-config.json`, `extensions`, `ide_state.json`, `mcp.json`, `projects/<name>/{agent-tools,rules,terminals}`; no `chats/` and no `agent-transcripts/` here.
  - Process names, from Cursor's own `process-monitor/*.log`: `Cursor Helper`, `Cursor Helper (GPU)`, `Cursor Helper (Renderer)`, `Cursor Helper (Plugin)`. Apple's `CursorUIViewService` (TextInputUIMacHelper) runs on every Mac and must never match.
  - Assumed, not verified: the main process name `Cursor`; `composer.composerHeaders` in `ItemTable` as `{"allComposers": [{composerId, name, createdAt, lastUpdatedAt, workspaceIdentifier: {id, uri}}]}` (Domovy accepts that or a bare list and goes read-only for any other shape); `agentKv:<chat id>:…` keys (only those are treated as one chat's; other `agentKv:` rows are shared); CLI chats `~/.cursor/chats/<hash>/<id>/store.db` with a `meta` table holding the name as hex JSON under key `0`, and the `cursor-agent` process name; `~/.cursor/projects/*/agent-transcripts/<chat id>.txt`.

**Gemini CLI and Antigravity**
- Gemini CLI sessions: `~/.gemini/tmp/<project_hash>/chats/`. Manual `/chat` checkpoints and file checkpoints are in `~/.gemini/tmp/<project_hash>/checkpoints`. The shadow git repo for file snapshots is `~/.gemini/history/<project_hash>`. Deleting a session also removes its plans, task trackers, tool outputs and activity logs. — [gemini-cli session-management.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md); [checkpointing.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/checkpointing.md)
- One third-party source says files are named `session-<date>-<id>.jsonl` and that `~/.gemini/projects.json` maps folders to ids. Unverified against official docs. — [groundedby.com](https://groundedby.com/agents/gemini-cli)
- Antigravity, per a third-party guide: `~/.gemini/antigravity/` contains
  - `brain/<id>/` (`transcript.jsonl`, `transcript_full.jsonl`, tool output, `implementation_plan.md`, `walkthrough.md`)
  - `conversations/<id>.db` plus `-wal` and `-shm` (legacy `.pb`)
  - `annotations/<id>.pbtxt`
  - `presence/<id>.lock`
  The Antigravity CLI uses `~/.gemini/antigravity-cli/{conversations,brain}`. — [deja-vu guide](https://vshulcz.github.io/deja-vu/guide/delete-antigravity-history.html); [google-antigravity/antigravity-cli#1417](https://github.com/google-antigravity/antigravity-cli/issues/1417); [Google AI forum](https://discuss.ai.google.dev/t/how-to-delete-conversation-antigravity/114671)
- Verified on a real install (Gemini CLI 0.43.0 via Homebrew, Antigravity CLI `agy` 1.5.8, 2026-11-23; names, sizes, nesting, JSON key shapes, SQLite schemas and row counts only, plus the Gemini CLI source in its npm bundle; no chat or conversation content read):
  - Gemini CLI project folders are `~/.gemini/tmp/<name>/` and `~/.gemini/history/<name>/`, where `<name>` comes from `~/.gemini/projects.json` (`{"projects": {"<project path>": "<name>"}}`), not a hash. Each folder has `.project_root` (the project path). The chat's `projectHash` is the sha256 of that path.
  - Chats: `tmp/<name>/chats/session-<YYYY-MM-DD>T<HH-MM>-<first 8 chars of the session id>.jsonl`. First line `{sessionId, projectHash, startTime, lastUpdated, kind: main|subagent}`; then messages `{id, timestamp, type: user|gemini|info, content (string or [{text}]), model?, thoughts?, tokens?, toolCalls?}` and `{"$set": {lastUpdated, messages}}` lines that replace the whole message list, or `{"$set": {summary}}`. Subagent chats sit in `chats/<parent session id>/<agent id>.jsonl`. Older versions wrote one `session-*.json` object.
  - Session ids are not unique per file: 427 chats here share one id (files ending `-a2a-serv.jsonl`, apparently Gemini CLI's a2a server), most of them metadata only.
  - Per-session companions (from the source): `tmp/<name>/logs/session-<id>.jsonl`, `tmp/<name>/tool-outputs/session-<id>/`, `tmp/<name>/<id>/`. `tmp/<name>/logs.json` is a JSON array of typed prompts `{sessionId, messageId, timestamp, type, message}` shared by the project. `history/<name>/` is a shadow git repo (`.git`, `.gitconfig`, `.gitignore`).
  - `gemini --help` (0.43.0) lists `--list-sessions` and `--delete-session <string>` ("Delete a session by index number"). The source matches the argument against session ids first and falls back to a 1-based index (`parseInt`), so an id that is not listed and starts with digits picks another chat. Deletion removes every `session-*-<first 8 chars>.json(l)` of the project found from the working directory, plus the companions above. It always exits 0. Before handling the flag, startup runs the retention sweep for that project. Chats without user or model messages are not listed.
  - Retention (source): `general.sessionRetention` = `{enabled: true, maxAge: "30d", maxCount, minRetention: "1d"}` by default; units h, d, w, m (30 days); an invalid value disables the sweep. Keyed on the chat's `lastUpdated`; chats without messages are always deleted; runs per project at startup. The user's `settings.json` here has no `general` key (defaults apply).
  - `GEMINI_CLI_HOME` replaces the home folder (Gemini CLI then uses `$GEMINI_CLI_HOME/.gemini`).
  - Gemini CLI runs as `node …/@google/gemini-cli/bundle/gemini.js` (shebang); Google's separate `Gemini.app` runs as `Gemini`, so process matching must not be case-insensitive.
  - Antigravity CLI store is `~/.gemini/antigravity-cli/`: `conversations/<uuid>.db` (+ `-wal`, `-shm`), `brain/<uuid>/` (`.system_generated/{logs,messages,tasks}`, `.user_uploaded`, `scratch/`, sometimes a `.git`, artifact files with `.metadata.json`), `conversation_summaries.db` (table `conversation_summaries`: `conversation_id, title, preview, step_count, last_modified_time, workspace_uris, status, …`), `cache/conversation_metadata.json` (`{"conversations": {"<id>": {summary?: {ID, Title, Preview, NumSteps, UpdatedAt, WorkspaceURIs, …}, is_internal, last_modified_time}}}`), `history.jsonl` (`{display, timestamp, workspace, conversationId?, type?}`), `implicit/<uuid>.pb`, `settings.json`, `antigravity-oauth-token`, `bin/`, `builtin/`, `updater/`, `knowledge/`, `log/`, `crashes/`. No `presence/` or `annotations/` here. Conversation tables: `trajectory_meta, steps, gen_metadata, executor_metadata, parent_references, trajectory_metadata_blob, battle_mode_infos`.
  - `agy --help` (1.5.8) has no delete, archive or prune command. `agy` is a native binary, so its process name is `agy`.
  - Assumed, not verified (not installed here): the Antigravity desktop app's `~/.gemini/antigravity/` store with `annotations/<id>.pbtxt` and `presence/<id>.lock`, its process names (`Antigravity`, `Antigravity Helper …`), and that its 500-conversation prune matches the CLI's; that Gemini CLI also runs as a `gemini` binary in other installs; that a project's own `.gemini/settings.json` may override retention (Domovy reads only the user settings); that `--delete-session` works in an untrusted folder.

**OpenCode**
- All sessions are in one SQLite DB, `~/.local/share/opencode/opencode.db`, with tables `session`, `part` (message content, including inline base64 attachments), `event` (an append-only event log, one stream per session) and `event_sequence`. — [anomalyco/opencode#53760](https://github.com/anomalyco/opencode/issues/53760); [#32716](https://github.com/anomalyco/opencode/issues/32716)
- Extra per-session files: `~/.local/share/opencode/storage/session_diff`, plus `snapshot/` and `log/`. — [bernard-denis/opencode-cleaner](https://github.com/bernard-denis/opencode-cleaner); [agent-cleanup README](https://github.com/luchasarie/agent-cleanup)
- `~/.opencode/bin/opencode` is a CLI install location. — [opencode-cleaner](https://github.com/bernard-denis/opencode-cleaner)
- Verified on a real install (OpenCode 1.18.30, installed at `~/.opencode/bin/opencode`, a native arm64 binary, 2026-11-23; names, sizes, SQLite schema, row counts and JSON key names only, read from a copy of the database; no titles, messages or other values read):
  - `~/.local/share/opencode/`: `opencode.db` with `-wal` and `-shm` (WAL mode, page size 4096), `log/opencode.log`, `snapshot/<40-hex>/` (a bare git repository per project), `repos/` (empty here). No `storage/` folder and no `auth.json` in this install. Settings are in `~/.config/opencode/` (`opencode.json`, `package.json`, `node_modules/`); `~/.local/state/opencode/` holds `model.json`, `prompt-history.jsonl` and `locks/`; `~/.cache/opencode/` holds `models.json`.
  - Tables: `session` (`id` "ses_" + 26 characters, `project_id`, `workspace_id`, `parent_id`, `slug`, `directory`, `path`, `title`, `version`, `share_url`, summary and token columns, `time_created`, `time_updated`, `time_compacting`, `time_archived`; times in milliseconds), `message` (`id, session_id, time_created, time_updated, data` JSON with `role` user|assistant, `time`, `agent`, `model`, `cost`, `tokens`, …), `part` (`id, message_id, session_id, …, data` JSON with `type` text|tool|reasoning|step-start|step-finish, `text`, `tool`, `state`, …), `event` (`id, aggregate_id, seq, type, data`; `aggregate_id` is the session id, types like `session.created.1`, `message.part.updated.1`), `event_sequence`, `session_message`, `session_input`, `session_context_epoch`, `session_share`, `todo`, `project`, `project_directory`, `workspace`, `permission`, `account`, `control_account`, `credential` (sign-in tokens live in the same file), `data_migration`, `migration`. `session.parent_id` links subagent sessions to their parent. Here: 3 sessions, 12 messages, 32 parts, 107 events; `event` held 110 KB of 438 KB of pages (`dbstat`).
  - `opencode --help` lists `session`, `export`, `import`, `stats`, `db`, `upgrade`, `uninstall`, …; `opencode session --help` lists `list` and `delete <sessionID>`; global options include `--pure` ("run without external plugins"). `opencode db` opens a sqlite3 shell or runs a query; there is no compaction or prune command. Help goes to stderr. Running `--version`/`--help` left the database untouched.
  - Assumed, not verified: that `opencode session delete` also removes the session's `message`, `part` and `event` rows (Domovy checks afterwards and reports what stays), that it does not ask for confirmation without a terminal, and that it honours `XDG_DATA_HOME`; `storage/session_diff/<id>.json` of older versions; the npm package's process (`node …/opencode-ai/…`).

**GitHub Copilot CLI (`~/.copilot`, or `$COPILOT_HOME`)**
- `session-state/<session-id>/` contains `events.jsonl` plus workspace artifacts (plans, checkpoints, tracked files). `session-store.db` is a SQLite index used for search and `/chronicle`. `logs/process-{timestamp}-{pid}.log` holds per-process logs. `command-history-state/` holds command history. — [GitHub Docs: CLI config dir](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)
- Not installed where Domovy is developed (checked 2026-11-23: no `~/.copilot`, no `copilot` on `$PATH`). Domovy's adapter is built from the documentation above and marked assumed: the `events.jsonl` line shape `{type, data, id, timestamp}` with `session.start` (`data.context.cwd`), `user.message` and `assistant.message` (`data.content`, `data.toolRequests`); an optional `workspace.yaml` with `summary:` and `cwd:`; `inuse.<pid>.lock` in a session folder while it is open; the protected entries `config.json`, `mcp-config.json`, `permissions-config.json`, `agents/`, `skills/`, `hooks/`, `extensions/`; `history-session-state/` of older versions; the process name `copilot` (native) or `node …/@github/copilot/…`; and `session-store.db`'s schema (Domovy counts rows whose `session_id`, `sessionId` or `id` equals the session id, read only).

**Local model stores**
- Ollama: models live in `~/.ollama/models` on macOS (`OLLAMA_MODELS` overrides), with `manifests/` and content-addressed `blobs/`. — [Ollama FAQ](https://github.com/ollama/ollama/blob/main/docs/faq.mdx)
- `ollama rm` removes the manifest for the tag and every layer no other manifest still references. — [centron tutorial](https://centron.de/en/tutorials/managing-ollama-models-updates-cleanup)
- The server prunes unreferenced blobs unless `OLLAMA_NOPRUNE` is set, with a 1-hour grace period for new blobs. — [ollama server/images.go v0.40.11 (snippet)](https://github.com/ollama/ollama/blob/v0.40.11/server/images.go); [server/create.go v0.40.1 (snippet)](https://github.com/ollama/ollama/blob/v0.40.1/server/create.go)
- LM Studio: `~/.lmstudio/models` (older versions used `~/.cache/lm-studio/models`). `~/.lmstudio` also holds settings, extensions and credentials. — [purgy.app (third-party)](https://purgy.app/blog/lm-studio-models-storage-mac); [aikiller guide (third-party)](https://aikiller.yogisoftworks.com/guides/lm-studio-huggingface-cache-mac)
- An `lms remove` CLI command was still an open feature request as of 2026-06-08. — [lmstudio-ai/lms#579](https://github.com/lmstudio-ai/lms/issues/579)
- Hugging Face: `~/.cache/huggingface/hub` (`HF_HOME` or `HF_HUB_CACHE` override), one `models--org--name/` per repo with `refs/`, `blobs/` (named by hash), `snapshots/<rev>/` (symlinks to blobs) and `.no_exist/`.
  - Xet-shared files are stored once at `<CACHE_DIR>/blobs/<prefix>/<xet_hash>`, with a `<xet_hash>.refs` manifest.
  - `~/.cache/huggingface/xet` holds the shard cache, with a 16 GB soft limit.
  - `hf cache ls`, `hf cache rm` and `hf cache prune` manage the cache.
  — [HF docs: manage cache](https://huggingface.co/docs/huggingface_hub/guides/manage-cache)
- Verified on a real install (2026-11-23; names, sizes, mtimes, manifest key schemas and digests only; no model content read):
  - Ollama (client 0.33.3, Homebrew `/opt/homebrew/bin/ollama`): `~/.ollama/models/manifests/registry.ollama.ai/library/<model>/<tag>` (2 models) and a flat `blobs/` of `sha256-<64 hex>` files (10 blobs, 17 GB). Manifest keys: `schemaVersion` (2), `mediaType` (`application/vnd.docker.distribution.manifest.v2+json`), `config` and `layers[]`, each `{digest, mediaType, size}`; digest `sha256:<hex>` maps to blob file `sha256-<hex>`. Layer media types `application/vnd.ollama.image.{model,template,license,params}`, config `application/vnd.docker.container.image.v1+json`. Every blob was referenced by a manifest (no orphans here). Manifest mtime equals pull time; atime equals mtime, so it says nothing about use.
  - `~/.ollama` also holds `id_ed25519` keys, `config.json`, `history`, `backup/`, `cache/`.
  - `ollama --version`, `list`, `ps` and `rm` all talk to the server over HTTP: with the server down, `list` and `ps` fail ("could not connect to ollama server") and `--version` prints only the client version. `ollama rm MODEL [MODEL...]` takes several models. Help lists no `prune`.
  - Hugging Face hub (`~/.cache/huggingface/hub`, 1 model repo, 1.4 GB): `models--<org>--<name>/{refs/main, snapshots/<40-hex commit>/, blobs/, .no_exist/<commit>/}`; snapshot entries are relative symlinks `../../blobs/<hash>`. Small files sit in the repo's `blobs/` as regular files; large ones are symlinks `../../blobs/<2-hex prefix>/<64-hex hash>` into a hub-level shared store, next to `<hash>.refs` and `<hash>.lock`. Also `hub/blobs/.huggingface-shared-blobs`, `hub/.locks/<repo>/*.lock`, `CACHEDIR.TAG`, and `~/.cache/huggingface/xet/` (shard cache, 208 KB).
  - Not installed here: LM Studio (`~/.lmstudio`, `~/.cache/lm-studio`), the `hf` and `huggingface-cli` CLIs, `lms`.
  - Assumed, not verified: the Ollama server's process name (`ollama`; the app as `Ollama`) and that a loaded model shows in `ollama ps` with the `NAME` column first; that `ollama rm` also deletes unshared blobs (unless `OLLAMA_NOPRUNE`), which Domovy verifies after each run; LM Studio's `models/<publisher>/<model>/` layout and process names (`LM Studio`, `LM Studio Helper ...`); the `hf cache rm <type>/<org>/<name> --yes` and `hf cache prune --yes` argument forms (Domovy only runs `hf` when `hf cache --help` lists `rm` and `prune`, and verifies the result). Domovy never reads `.refs` files.

### Inferences
- The session key differs by agent:
  - Claude Code: (project-dir slug, session UUID).
  - Codex: thread UUID, embedded in the rollout filename and the `threads.id` column.
  - Cursor: `composerId`.
  - Copilot: session-id directory.
  - Gemini: (project_hash, session id).
  - OpenCode: `session.id` inside the DB.
- A Claude Code "delete session" should remove:
  - the `.jsonl`
  - its sibling `<session>/` dir (`subagents`, `tool-results`, `mcp-tasks`)
  - `.orphaned-*` and `.superseded-*` siblings
  - `file-history/<session>/`
  - `debug/` and `session-env/` entries for that id
  - `uploads/`, `image-cache/` and `dev-mods/` `<session>` dirs
  - the temp-dir scratchpad and images
  - matching `history.jsonl` lines (optional)
  - the Desktop `local_*.json` whose `cliSessionId` matches
  It should never remove `projects/<project>/memory/`.
- `debug/` and `session-env/` may be named by session id, but the docs do not state their internal naming. Verify on disk.

### Gaps
- Exact filenames inside `debug/`, `session-env/`, `tasks/` and `plans/`, and whether they embed the session id, are not documented. Check them locally.
- The full directory tree of `claude-code-sessions` (account and org subdirectories) and of `local-agent-mode-sessions` on macOS, beyond the `<dir>/<dir>/local_<id>.json` shape, is not documented.
- No source found for Claude Desktop logs (`~/Library/Logs/Claude` is unverified).
- Codex "screenshots/images" storage and duplicate-screenshot bloat: no source found (searched openai/codex issues). The bloat source that is confirmed is inline base64 images inside rollouts.
- Cursor ".pack files": no source found. Mark unverified.
- No official LM Studio docs were fetched. Paths come from third-party pages.

## Q2. Indexes, registries and DBs that also reference a session (dangling-entry risk)

### Takeaway
Every major agent except Claude Code CLI keeps a second store besides the transcript. If the app deletes only files, it leaves stale UI entries or errors: Claude Desktop shows "Session not found on disk", Codex keeps a stale `threads` row and `session_index` entries, Cursor chats can resurrect, and Copilot needs a reindex. Use the vendor's own delete path where one exists. Otherwise, edit the index while the app is fully quit.

### Cited Findings
- Claude Desktop: the `local_*.json` registry and the CLI transcript are separate. Desktop delete removes only the registry entry. When the transcript is swept, the sidebar keeps the entry and shows an empty conversation or "Session not found on disk", and the app marks it `transcriptUnavailable`. — [#89547](https://github.com/anthropics/claude-code/issues/89547); [#99817](https://github.com/anthropics/claude-code/issues/99817); [#105500](https://github.com/anthropics/claude-code/issues/105500)
- The app overwrites edits to `local_*.json` unless Claude is fully quit. — [#73959](https://github.com/anthropics/claude-code/issues/73959)
- Claude Code CLI: `/resume` lists sessions straight from `projects/` (no separate index found in the docs). `~/.claude.json` keeps per-project entries, and `backups/` may hold copies of them. — [claude-directory](https://code.claude.com/docs/en/claude-directory)
- Agent view's `jobs/<id>/state.json` and `daemon/roster.json` reference background sessions. Deleting there with `claude rm` keeps the transcript. — [agent view](https://code.claude.com/docs/en/agent-view)
- Codex hard delete (source):
  1. Rejects deletion when attached child threads exist or forked history references the thread.
  2. Removes host-owned data.
  3. Deletes the plain and `.zst` rollouts.
  4. Removes `session_index.jsonl` name entries.
  5. Deletes state DB rows under a lifecycle lock.
  It also refuses to run when the diagnostic logs DB is unavailable. — [delete_thread.rs](https://github.com/openai/codex/blob/main/codex-rs/thread-store/src/local/delete_thread.rs)
- Codex archive moves the rollout into `archived_sessions/` with `rename` and updates SQLite metadata (`archived`, `archived_at`). It rejects archiving if owned descendants are not archived too. — [archive_thread.rs](https://github.com/openai/codex/blob/main/codex-rs/thread-store/src/local/archive_thread.rs); [0001_threads.sql](https://github.com/openai/codex/blob/main/codex-rs/state/migrations/0001_threads.sql)
- Codex reference index: fork relationships and attached children are indexed by scanning active and archived rollout metadata. — [rollout_reference_index.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/rollout_reference_index.rs)
- Known Codex bugs:
  - Delete removed the payload but left a stale `threads` row, and each later delete then errored. — [openai/codex#36558](https://github.com/openai/codex/issues/36558)
  - Archive in Desktop deleted the data and left an orphan `session_index.jsonl` entry. — [#27545](https://github.com/openai/codex/issues/27545)
  - Archived sessions cannot be deleted on 0.166.0, where `codex delete --force` fails with "failed to delete session". — [#58366](https://github.com/openai/codex/issues/58366); [#55232](https://github.com/openai/codex/issues/55232)
- Cursor: a full chat delete must remove the `composerHeaders` / `allComposers` header, `composerData:`, `composerChatViewPane.*` panel refs in global and every workspace DB, and the `.backup` files. Otherwise deleted chats come back after restart. — [Cursor forum #156745 (snippet)](https://forum.cursor.com/t/deleted-chat-entries-permanently-resurrect-after-restart-root-cause-in-stale-panel-state-backup-file/156745)
- Cursor: missing `checkpointId` rows break continuation ("Blob not found"). — [cursaves](https://github.com/Callum-Ward/cursaves/blob/main/docs/how-cursor-stores-chats.md)
- Copilot CLI: after deleting `session-state/<id>`, `session-store.db` must be rebuilt with `/chronicle reindex`, which also syncs session data to the user's account. Local deletion does not affect synced data. — [GitHub Docs: chronicle how-to](https://docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/chronicle); [CLI config dir](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)
- Server-side copies:
  - Claude Code: deleting local `.jsonl` does not remove sessions from Anthropic servers, and `claude --resume <id>` reportedly restores them (user report). — [#26904 comment referencing #67201](https://github.com/anthropics/claude-code/issues/26904)
  - Copilot synced sessions survive local delete. — [GitHub Docs](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)
- Antigravity: `PruneAll(500)` deletes `.db` files ranked 501+ by mtime and recursively deletes `brain/<id>` through an onDelete callback. — [antigravity-cli#1417](https://github.com/google-antigravity/antigravity-cli/issues/1417), [#1403 (snippet)](https://github.com/google-antigravity/antigravity-cli/issues/1403)
- OpenCode: the official delete path is `opencode session delete`. The cleaner tool deletes children before parents and never edits the DB directly. — [opencode-cleaner](https://github.com/bernard-denis/opencode-cleaner)

### Inferences
- For Codex, call `codex delete <uuid> --force` and `codex archive` (the CLI or app-server) rather than unlinking files. Fall back to file removal only after verifying the `threads` row and `session_index` entries. Delete children first, because of the spawn-edge checks.
- For Claude Desktop sessions, a correct delete removes both the transcript set and the matching `local_*.json` (match on `cliSessionId`), and only while Claude Desktop is quit.
- For Cursor, editing `state.vscdb` by hand is risky. The safer route is Cursor's own commands, run inside Cursor.

### Gaps
- No documented schema for `local_*.json`. Field names come from user reports only.
- Whether Claude Desktop holds an index elsewhere (Local Storage or IndexedDB) that also lists sessions is not established. #55418 says those hold only UI state.

## Q3. Known bloat sources and safe cleanup

### Takeaway
The biggest bloat sources are:
- Claude Desktop's VM bundle (10-15 GB)
- Codex rollouts (multi-GB per file; 21-755 GB stores reported)
- Cursor `state.vscdb` (30-97 GB)
- OpenCode's `event` table (9 GB)
- agent worktrees (202 GB of Codex temp copies in one case)
Safe cleanup means quitting the app first and preferring vendor commands (Cursor GC, `codex delete`, `ollama rm`, `hf cache rm`). A database needs free space roughly equal to (up to twice) its size before VACUUM or compaction.

### Cited Findings
- Claude Desktop VM:
  - `rootfs.img` grows and is never trimmed (no fstrim or discard). One bundle was about 13 GB. — [#65577](https://github.com/anthropics/claude-code/issues/65577)
  - `rootfs.img` is 10 GiB, fully allocated, but only 4.73 GB of it is non-zero. Writing sparse files on APFS still ends up fully allocated; punching holes afterwards with `F_PUNCHHOLE` works. — [#107097](https://github.com/anthropics/claude-code/issues/107097)
  - `rootfs.img.zst` (1.14 GB) is kept after extraction, and provisioning writes 10.7 GB and trips the macOS disk-write limit. — [#89869](https://github.com/anthropics/claude-code/issues/89869)
  - One user reported about 15 GB in Nov 2026. — [#22543 comment](https://github.com/anthropics/claude-code/issues/22543)
- Is the VM bundle recreated after deletion? Sources conflict:
  - "It redownloads the bundle if you delete it" and "vm_bundles still recreates itself on every launch". — [#22543 comments](https://github.com/anthropics/claude-code/issues/22543)
  - Another commenter: "After 1 hour of having Claude desktop open, the VM storage was not recreated. The Cache and Code Cache came back immediately". — same thread
  - A Reddit user: "reopen Claude, and it should have a new VM". — [r/claude](https://reddit.com/r/claude/comments/1rb3lhc/claude_cowork_vm_full)
  - The bundle cannot be prevented from being generated. — [#100529 (title)](https://github.com/anthropics/claude-code/issues/100529)
- Deleting the bundle also destroys `sessiondata.img` (Cowork session state). On Windows, the "Delete Cowork VM Sessions" debug action also wiped scheduled tasks and local chat transcripts. — [#93583](https://github.com/anthropics/claude-code/issues/93583)
- `claudevm.bundle` stays on disk after Claude Desktop is uninstalled, about 10-12 GB. — [tw93/Mole#537 (closed)](https://github.com/tw93/Mole/issues/537)
- Claude Code: `~/.claude/` can grow to more than 1.8 GB across more than 10,000 files. — [GarrickZ2/claude-code-cleaner README](https://github.com/GarrickZ2/claude-code-cleaner)
- Claude Code: `/heapdump` `.heapsnapshot` files contain the full conversation and any credentials the process held, and neither the sweep nor purge removes them. — [claude-directory](https://code.claude.com/docs/en/claude-directory)
- Codex rollout bloat:
  - One 2.5 GB rollout held 397 `compacted` records (about 1.7 GB) and 552 inline base64 images. One store measured 34 GB: 21 GB sessions, 4.4 GB `state_5.sqlite`, 3.2 GB `thread_history_1.sqlite`. — [Sealkeep: Codex disk usage](https://sealkeep.spala.ai/guides/codex-sessions-disk-usage)
  - Subagents copy parent history: 755 GiB, of which 731.5 GiB came from 2,393 subagent files. — [#34061 via Sealkeep](https://sealkeep.spala.ai/guides/codex-sessions-disk-usage)
  - Resume duplicated the full context into new multi-GB rollouts. — [#29531](https://github.com/openai/codex/issues/29531)
- Codex worktrees: `~/.codex/worktrees` reached 3.8 GB with no list or prune command. Two of six worktrees held uncommitted work that existed nowhere else, and stale `/tmp` registrations need `git worktree prune`. — [openai/codex#54891](https://github.com/openai/codex/issues/54891)
- Cursor state.vscdb:
  - Sizes of 30 GB, 52 GB and 96 GB were reported, made up mostly of `bubbleId`, `agentKv` and `checkpointId` rows. — [forum #167641](https://forum.cursor.com/t/state-vscdb-grows-to-30gb-due-to-bubbleid-agentkv-entries/167641); [reddit](https://reddit.com/r/cursor/comments/1wsihxw/cursor_stuck_on_loading_chats_after_reboot_root)
  - About 50 rows were stored per visible message; three chats held 85% of the bubble rows. — [forum #170508](https://forum.cursor.com/t/agent-chat-db-state-vscdb-grows-without-bound-50-bubble-rows-per-visible-message-96-gb-and-climbing/170508)
- Cursor safe cleanup per Cursor staff:
  1. Run "Developer: Delete Old Chats…" with a day cutoff.
  2. Quit with Cmd+Q.
  3. Run "Developer: GC Agent KV Blobs", which removes orphans and compacts the DB. It needs free space of about 1-2x the file size.
  4. Quit fully again so the file shrinks.
  Do not delete `state.vscdb` while Cursor is open. `state.vscdb.backup` is no longer updated and can be deleted while Cursor is closed. Raw `DELETE ... VACUUM` on `agentKv`, `bubbleId` and `checkpointId` deletes all chats. — [forum #173914](https://forum.cursor.com/t/excessive-storage-in-macbook/173914); [forum #169927](https://forum.cursor.com/t/how-can-i-reduce-the-size-of-the-state-vscdb-file-without-deleting-chats/169927); [forum #171211 (snippet)](https://forum.cursor.com/t/macos-globalstorage-61-1gb/171211)
- Cursor GC caveats: GC took one DB from 82 GB to only 66.66 GB because it reclaims orphans only. It produced a 66.59 GB `-wal` file, and space is not freed until a full quit checkpoints the WAL. The quit looks like a hang. — [forum #170508](https://forum.cursor.com/t/agent-chat-db-state-vscdb-grows-without-bound-50-bubble-rows-per-visible-message-96-gb-and-climbing/170508)
- OpenCode: `opencode.db` reached 11.37 GB, of which 9.03 GB was `event` payload, with `freelist_count` 0, so VACUUM alone reclaims nothing. — [anomalyco/opencode#53760](https://github.com/anomalyco/opencode/issues/53760)
- OpenCode: base64 attachments in `part` caused an Electron OOM at a 1.25 GB DB. — [#32716](https://github.com/anomalyco/opencode/issues/32716)
- Ollama: no `prune` or `gc` subcommand on 0.33.0, and orphaned blobs (21 GB, 35 GB) remained after `rm` or interrupted pulls (user report). Do not delete blobs by hand, because a blob can belong to several models. — [ollama/ollama#18595 (snippet)](https://github.com/ollama/ollama/issues/18595); [mintdisk (third-party)](https://mintdisk.com/blog/ollama-storage)
- Hugging Face: `huggingface_hub<=1.31` leaves a deleted repo's shared Xet files in the store, and `hf cache prune` removes them. — [HF manage-cache](https://huggingface.co/docs/huggingface_hub/guides/manage-cache)

### Inferences
- The app should treat the Claude Desktop VM bundle as "reclaimable but may re-download", warn that Cowork session state and scheduled tasks may be lost, and require Claude Desktop to be quit. Hole-punching `rootfs.img` (F_PUNCHHOLE on zero ranges) while Claude is quit could reclaim about 5 GB without deleting anything. This is an experimental idea from #107097, not a vendor-supported action.
- Deleting `rootfs.img.zst` after extraction looks redundant (#89869), but whether the app needs it again is unverified.

### Gaps
- No official Anthropic statement found on whether deleting `vm_bundles` is supported or safe.
- No vendor-supported compaction found for Codex `state_5.sqlite` or `thread_history_1.sqlite`.

## Q4. Retention behavior

### Takeaway
- Claude Code: deletes silently at 30 days by default, based on file mtime. The minimum is 1, and `0` is now a validation error.
- Gemini CLI: also 30 days by default.
- Antigravity: prunes conversations beyond 500, ranked by mtime.
- Codex, OpenCode and Cursor: no documented age-based retention (Cursor has a manual "Delete Old Chats").
- Copilot: no retention documented.

### Cited Findings
- Claude Code sweep:
  - Runs as a background sweep after a session starts and deletes without a message. Default 30, minimum 1. The same cutoff applies to orphaned subagent and background-session worktrees.
  - Skipped in `--bare` mode, and paused when settings cannot be parsed.
  - Managed settings override the user's value.
  — [settings reference](https://code.claude.com/docs/en/settings-reference); [claude-directory](https://code.claude.com/docs/en/claude-directory)
- Desktop and Cowork transcripts are kept at any age, unless `desktopSessionCleanupPeriodDays` is set (v2.1.248+). Transcripts are deleted only once older than both limits. — [settings reference](https://code.claude.com/docs/en/settings-reference); [claude-directory](https://code.claude.com/docs/en/claude-directory)
- Deletion keys on file mtime via `fsImpl.stat().mtime < cutoff` followed by `unlink`. `cleanupPeriodDays: 0` deleted everything, based on the source quoted at the time. Closed as a duplicate of #59248. — [#62250](https://github.com/anthropics/claude-code/issues/62250)
- 76 of 97 Desktop-recorded sessions were destroyed. `~/.claude/.last-cleanup` holds the timestamp of the last sweep. Still open. — [#99817](https://github.com/anthropics/claude-code/issues/99817)
- The Desktop "Archive inactive sessions: Never" setting did not prevent deletion on Windows (Claude Code CLI 2.1.308). Closed as a duplicate of #99817 on 2026-11-15. — [#105500](https://github.com/anthropics/claude-code/issues/105500)
- Sweep coverage was extended to `tasks/`, `shell-snapshots/` and `backups/` in v2.1.117. — [#51779 (snippet)](https://github.com/anthropics/claude-code/issues/51779)
- A maintainer reproduced deletion on 2.1.233 and called it the documented default. — [Sealkeep guide](https://sealkeep.spala.ai/guides/claude-code-deletes-transcripts-after-30-days)
- Before v2.1.228, the sweep could delete files under `memory/`. — [claude-directory](https://code.claude.com/docs/en/claude-directory)
- Codex: the config reference documents `history.persistence` and `history.max_bytes`, which apply to `history.jsonl` only. No session retention setting was found in it. — [Codex config reference](https://developers.openai.com/codex/config-reference); [Sealkeep](https://sealkeep.spala.ai/guides/codex-sessions-disk-usage) ("The official docs document no session-retention setting")
- The agent-cleanup README lists Codex built-in retention as "none". — [agent-cleanup](https://github.com/luchasarie/agent-cleanup)
- Codex compression: compresses rollouts older than 7 days when `local_thread_store_compression` is on (off by default). — [compression.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/compression.rs)
- Gemini CLI: `general.sessionRetention` has `enabled`, `maxAge` (default "30d"), `maxCount` (unlimited) and `minRetention` ("1d"). The current docs say retention is on by default. An older fork of the docs said `enabled` defaulted to `false`. — [gemini-cli docs](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md); conflicting older text in [zed-industries fork](https://github.com/zed-industries/gemini-cli/blob/main/docs/cli/session-management.md)
- Antigravity CLI: hardcoded `PruneAll(500)` on startup, ranked by mtime, deletes pinned and open conversations. Open. — [antigravity-cli#1417](https://github.com/google-antigravity/antigravity-cli/issues/1417)
- Cursor: no automatic retention. Staff say "the team is working on automatic cleanup". Manual cleanup is "Developer: Delete Old Chats…". — [forum #173914](https://forum.cursor.com/t/excessive-storage-in-macbook/173914)
- OpenCode: there is no retention policy (feature request #32716, now closed). `"snapshot": false` turns snapshots off. — [#32716](https://github.com/anomalyco/opencode/issues/32716); [agent-cleanup](https://github.com/luchasarie/agent-cleanup)

### Inferences
- Claude Code and Antigravity both key deletion on mtime. Any operation in the Swift app that changes mtime (copying without preserving dates, decompressing, re-writing, or "touching") can shift sessions into or out of the deletion window. The app must preserve mtimes exactly.
- APFS compression with applesauce uses a temp file and atomic rename. Whether that rename preserves mtime should be tested.
- An app feature that warns "N sessions will be deleted by Claude Code at next launch" (mtime older than `cleanupPeriodDays`) would be valuable.

### Gaps
- Whether Codex has any automatic age-based cleanup in late-2026 builds: none found in source or docs (absence of evidence).

## Q5. Official delete and archive commands

### Takeaway
- Codex: has `codex archive`, `codex unarchive` and `codex delete [--force]`, which are stable CLI commands, with known bugs for archived sessions.
- Claude Code: has no per-session delete. It has `claude purge` (per project or `--all`) and `claude rm` for background sessions, which keeps the transcript.
- Gemini CLI: has `--delete-session`.
- Cursor: has "Delete Old Chats" and the CLI picker delete.
- OpenCode: has `opencode session delete`.

### Cited Findings
- Codex:
  - `codex archive <SESSION>` and `codex unarchive <SESSION>` take an ID or name and also archive or restore the subagent descendants.
  - `codex delete <SESSION>` / `codex delete <SESSION_UUID> --force` deletes permanently; `--force` requires a UUID.
  - All are marked Stable and support `--remote` to an app-server.
  — [Codex CLI reference](https://developers.openai.com/codex/cli/reference)
- `codex delete` was added in 0.141.0 according to the thread on #24948. — [Sealkeep](https://sealkeep.spala.ai/guides/codex-sessions-disk-usage)
- Without a TTY and without `--force`, `codex delete` refuses with "cannot confirm session deletion without an interactive terminal". — [#58366](https://github.com/openai/codex/issues/58366)
- Codex has a `migrate-rollouts` subcommand. — [#54891](https://github.com/openai/codex/issues/54891)
- Claude Code `/delete` (#26904) is still open. Requests: `/delete` and `/delete <name>`. — [#26904](https://github.com/anthropics/claude-code/issues/26904)
- `claude purge [path] [--all] [--dry-run]` deletes, for one project, transcripts and auto memory under `projects/`, per-session `tasks/`, `debug/` and `file-history/`, matching `history.jsonl` lines, and the project's `~/.claude.json` entry. It leaves `shell-snapshots/`, `backups/` and temp-dir images and scratchpads. It was named `claude project purge` before v2.1.288. — [claude-directory](https://code.claude.com/docs/en/claude-directory)
- `claude rm <id>` and agent-view Ctrl+X delete background sessions but keep the transcript. Agent view removes the worktree even with uncommitted changes. `claude rm` keeps a worktree that has uncommitted changes. — [agent view](https://code.claude.com/docs/en/agent-view); [sessions](https://code.claude.com/docs/en/sessions)
- Gemini CLI: `gemini --delete-session <index|id>` deletes a session, and `/chat delete <tag>` (equivalent to `/resume delete <tag>`) deletes a checkpoint. — [session-management.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md); [commands.md (snippet)](https://github.com/google-gemini/gemini-cli/blob/main/docs/reference/commands.md)
- Cursor CLI: `cursor agent ls`, then Backspace or Delete on a chat. Or `rm -rf ~/.cursor/chats/<hash>/<uuid>` when the agent is not using it. — [forum #156640](https://forum.cursor.com/t/cursor-agent-create-chat-and-how-to-delete-old-chats/156640)
- OpenCode: `opencode session delete`, and `opencode db "<query>"` for read queries. — [opencode-cleaner](https://github.com/bernard-denis/opencode-cleaner); [#53760](https://github.com/anomalyco/opencode/issues/53760)
- Ollama: `ollama rm <model>:<tag>`. HF: `hf cache rm` and `hf cache prune`. — [centron](https://centron.de/en/tutorials/managing-ollama-models-updates-cleanup); [HF docs](https://huggingface.co/docs/huggingface_hub/guides/manage-cache)
- Codex issue tracking for deletion and retention UX is fragmented (#13018, #20251, #8784, #6015). There is also an open request for a session-deleted hook event (#54730). — [openai/codex#28187](https://github.com/openai/codex/issues/28187)

### Inferences
- The Swift app should shell out to `codex delete --force <uuid>` and `codex archive` when the binary is present, verify the result against `state_5.sqlite` and the filesystem, and surface #58366-style failures.
- For Claude Code, the app must implement per-session delete itself, mirroring the sweep's artifact list.

### Gaps
- No Claude Desktop CLI or API to delete or archive Code-tab sessions was found, apart from the UI and editing the JSON.

## Q6. Existing cleanup tools and their gaps

### Takeaway
Existing tools work at the category or project level (claude-code-cleaner, agent-cleanup, Mole, poo), focus on worktrees and caches (poo, agent-cleanup, leftovers), or compress files (compress-agent-sessions). None of the tools reviewed does a correct per-session delete across both the transcript and the registry or DB for Claude Desktop, Codex and Cursor.

### Cited Findings
- **GarrickZ2/claude-code-cleaner** (Rust TUI):
  - Five-screen flow (Scan, Select, Projects, Preview, Clean), cleaning by category.
  - Categories: `projects/`, `debug/`, `file-history/`, `telemetry/`, `shell-snapshots/`, `plugins/`, `transcripts/`, `todos/`, `plans/`, `usage-data/`, `tasks/`, `paste-cache/`, `.claude.json.backup*`, `history.jsonl` (trimmed), and surgical `~/.claude.json` cleanup.
  - Detects orphan projects (original path missing), filters by expiry (default 30 days) and offers a dry run.
  - Protects `settings.json`, `CLAUDE.md`, `skills/`, `commands/`, `agents/`, `ide/` and `credentials.json`.
  — [README](https://github.com/GarrickZ2/claude-code-cleaner)
  - Gap (inference): it treats `plugins/` as cleanable, which conflicts with the docs' "Don't delete `~/.claude/plugins/`". It is Claude-only and has no Desktop registry or session-level delete. — [claude-directory](https://code.claude.com/docs/en/claude-directory)
- **morajabi/poo** (macOS menu-bar app and CLI, macOS 15+, signed and notarized):
  - Cleans dev disk space (DerivedData, Rust `target`, worktrees) with cold, warm and review tiers.
  - Never includes anything running. Backs up worktrees before removal (stashes uncommitted work, saves detached commits to a branch, keeps a `poo backups` restore), and removes them with `git worktree remove`.
  - Full Disk Access is optional. Without it, it skips TCC-guarded folders.
  - Never deletes through symlinks.
  - Covers worktrees and caches of Claude Code, Codex, Cursor and Conductor, plus Ollama and LM Studio stores. Has an MCP server and opt-in agent hooks.
  - Gap (inference): it is about build artifacts and worktrees, not session transcripts or registries.
  — [README](https://github.com/morajabi/poo)
- **arpwal/leftovers** (menu-bar app):
  - Focuses on memory: per-process footprint of agent sessions and duplicate MCP servers.
  - Disk view: dev caches; AI Models (Ollama, HF, LM Studio, where removing an Ollama model keeps shared layers); Docker; node_modules; simulators; Time Machine snapshots.
  - Worktree view: detects squash-merged branches, uses read-only checks and keeps branches.
  - Gap (inference): it does not manage sessions or transcripts.
  — [README](https://github.com/arpwal/leftovers)
- **ariccio/compress-agent-sessions** (macOS script):
  - Applies APFS `UF_COMPRESSED` transparent compression (LZFSE default, about 5-50x on JSONL) to `~/.claude/projects/*/*.jsonl`, `~/.codex/sessions/**`, and `~/.gemini/sessions/` if present.
  - Prefers applesauce, then afsctool, then `ditto --hfsCompression` (described as "unreliable on APFS").
  - Skips files modified within 15 minutes, files open in any process (`lsof`), the current Codex month directory, files younger than 14 days, and files already compressed.
  - Keeps a ledger and offers `restore`. Notes that any write decompresses the whole file.
  - Gaps (inference): no deletion; the Gemini path may be wrong (official is `~/.gemini/tmp/<hash>/chats`); it does not discuss the mtime interaction with the Claude sweep.
  — [README](https://github.com/ariccio/compress-agent-sessions)
- **luchasarie/agent-cleanup** (Agent Skill plus Python CLI):
  - Scans worktrees, merged branches, `node_modules`, package caches, agent logs and the Trash, with REMOVE, NEEDS-DECISION, KEEP-ACTIVE and SKIP classes.
  - Agent data older than `--keep-days` 30 is NEEDS-DECISION. It never touches Claude `memory/`.
  - Saves unmerged commits under `refs/agent-cleanup/`.
  - Has a table of agent folders and built-in retention.
  - Gap (inference): sessions are handled as whole log folders, with no registry or DB consistency.
  — [README](https://github.com/luchasarie/agent-cleanup)
- **tw93/Mole**: a general Mac cleaner and uninstaller with an agent skill or plugin. Purge removes rebuildable artifacts inside agent worktrees, never the worktrees themselves. Issue #537, which asks it to clean `claudevm.bundle`, is closed. Whether it was implemented is unverified (not found in the README). — [README](https://github.com/tw93/Mole); [#537](https://github.com/tw93/Mole/issues/537)
- **Sealkeep** (sealkeep.spala.ai): encrypted backup and search for Claude Code and Codex sessions, not a cleaner. Its guides (checked against Claude Code 2.1.319 and Codex 0.166.0) recommend `rsync -a` without `--delete` to back up `~/.claude/projects/` and warn about mtime-keyed deletion. — [Sealkeep](https://sealkeep.spala.ai); [guide](https://sealkeep.spala.ai/guides/claude-code-deletes-transcripts-after-30-days)
- Other tools found:
  - BasedGPT/claude-code-session-recovery: maps Desktop metadata to transcripts with `diagnose.py`. — [#89547 comment](https://github.com/anthropics/claude-code/issues/89547)
  - ihoooohi/claude-code-session-cleaner: a `/delete-session` command. — [#26904 comment](https://github.com/anthropics/claude-code/issues/26904)
  - iamquang95/codex-clean: removes `~/.codex/worktrees/{id}` and `repo/.git/worktrees/name`, and deliberately leaves `session_index.jsonl` alone. — [codex-clean](https://github.com/iamquang95/codex-clean)
  - bernard-denis/opencode-cleaner. — [repo](https://github.com/bernard-denis/opencode-cleaner)

### Inferences
- The gaps the new app can fill:
  1. Per-session, multi-artifact delete with registry and DB consistency for Claude Desktop, Codex and Cursor.
  2. An orphan finder: transcripts with no Desktop registry entry, registry entries with no transcript, Codex DB rows with no rollout and the reverse, and Desktop restart duplicates.
  3. A warning about the upcoming retention sweep.
  4. Archive (compress, or move to a user archive) that preserves mtime.
  5. VM bundle reclaim.

### Gaps
- The source code of these tools was not audited. The descriptions above come from their READMEs.

## Q7. macOS implementation notes

### Takeaway
Use `FileManager.trashItem` for reversible deletes. Use APFS decmpfs compression (applesauce-style, with temp file and atomic rename) for cold archives. Check for open file handles with libproc or `lsof`, and look for running agent processes, before touching anything. Expect TCC "data from other apps" prompts only for sandboxed app containers; Full Disk Access is optional for these paths.

### Cited Findings
- `FileManager.trashItem(at:resultingItemURL:)` "Moves an item to the trash". The output URL gives the item's new location, and "the actual name of the item may be changed when moving it to the trash". — [Apple docs](https://developer.apple.com/documentation/foundation/filemanager/trashitem(at:resultingitemurl:))
- APFS transparent compression uses the `UF_COMPRESSED` flag (HFS+ `com.apple.decmpfs` heritage). Data is stored inline in an xattr or in a resource-fork extent. Any write decompresses the whole file. — [compress-agent-sessions README](https://github.com/ariccio/compress-agent-sessions)
- applesauce compresses to a temp file and renames it atomically, so "the file is never left in an invalid state". It skips files that would grow and supports LZFSE, LZVN and ZLIB. — [applesauce README](https://github.com/Dr-Emann/applesauce)
- APFS will not keep zero ranges sparse when they are written via seek or ftruncate; `fcntl F_PUNCHHOLE` after writing does work (user testing). — [#107097](https://github.com/anthropics/claude-code/issues/107097)
- TCC: macOS Sonoma asks for permission when an app accesses a file in another app's data container (sandboxed containers). The permission lasts while the app stays open. — [WWDC23 "What's new in privacy"](https://developer.apple.com/videos/play/wwdc2023/10053)
- The TCC service is `kTCCServiceSystemPolicyAppData`, introduced in macOS 14 for CVE-2023-42929. — [jhftss blog](https://jhftss.github.io/CVE-2023-42929-Why-Do-We-Need-The-App-Container-Protection)
- On macOS 26 the Claude Code CLI itself triggers repeated "access data from other apps" prompts. — [#79674](https://github.com/anthropics/claude-code/issues/79674); [#92784](https://github.com/anthropics/claude-code/issues/92784)
- poo treats Full Disk Access as optional and skips guarded folders without it. — [poo README](https://github.com/morajabi/poo)
- Liveness signals:
  - Claude Code's `~/.claude/sessions/` holds one file per running session, removed on exit. — [claude-directory](https://code.claude.com/docs/en/claude-directory)
  - `~/.claude/daemon/roster.json` lists running background sessions, and `claude agents --json` / `claude daemon status` report their state. — [agent view](https://code.claude.com/docs/en/agent-view)
  - Codex uses per-thread writer locks plus `rollout-maintenance.lock` and `rollout-compression.lock`. — [maintenance.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/maintenance.rs); [compression.rs](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/compression.rs)
  - Antigravity has `presence/<id>.lock`. — [deja-vu](https://vshulcz.github.io/deja-vu/guide/delete-antigravity-history.html)
- compress-agent-sessions skips files held open by any process (via `lsof`) and files with an mtime in the last 15 minutes. — [README](https://github.com/ariccio/compress-agent-sessions)
- Concurrency hazard: if two processes resume the same Claude session, both write to one transcript. — [sessions](https://code.claude.com/docs/en/sessions)
- Cursor: compaction needs free space of 1-2x the DB size, and the WAL is merged only on full quit. — [forum #170508](https://forum.cursor.com/t/agent-chat-db-state-vscdb-grows-without-bound-50-bubble-rows-per-visible-message-96-gb-and-climbing/170508)
- Claude Desktop overwrites edited session JSON if it is not fully quit. — [#73959](https://github.com/anthropics/claude-code/issues/73959)
- Hard links: Cowork hard-links attached files into `local-agent-mode-sessions`. Size accounting must deduplicate by inode, and deleting the link does not free the space. — [#82164 (title)](https://github.com/anthropics/claude-code/issues/82164)
- HF snapshots are symlinks to blobs. Report per-repo sizes as logical and cache-wide `size_on_disk` as physical. — [HF docs](https://huggingface.co/docs/huggingface_hub/guides/manage-cache)

### Inferences
- In Swift, detect live use with libproc (`proc_listpids` plus `proc_pidinfo(PROC_PIDLISTFDS)` and `proc_pidfdinfo(PROC_PIDFDVNODEPATHINFO)`) to enumerate open vnode paths, or shell out to `lsof -Fn +D <dir>`. No primary source was fetched for the libproc API; this is unverified, so check against Apple headers (`sys/proc_info.h`, `libproc.h`). Combine that check with:
  - mtime-recency checks
  - agent liveness files (`~/.claude/sessions/`, roster, Codex locks)
  - running-process checks for the Claude, Cursor, Codex and Antigravity apps before editing their DBs or JSON
- Moving to the Trash keeps the bytes on the same volume, so it frees no space until the Trash is emptied. Plaintext secrets also remain readable in `~/.Trash`. Offer "Trash" (reversible) and "Delete permanently" separately.
- For "archive", candidates are an APFS-compressed in-place file (transparent, so the agent can still resume it) or a zstd tarball in a user-chosen folder (smaller, but the agent can no longer resume it). Preserve mtime in both cases because of the Claude and Antigravity mtime-keyed sweeps.
- Codex's own `.jsonl.zst` compression is a separate mechanism from APFS compression. Applying APFS compression to already-zstd files is pointless.

### Gaps
- Not verified: whether `trashItem` works on files inside other apps' Application Support without prompts (it should, because those are not sandbox containers).
- Not verified: whether Claude Desktop, Cursor or the Codex app are sandboxed, which would bring their data into the `kTCCServiceSystemPolicyAppData` prompt scope.
- No primary Apple source was fetched for the libproc APIs or the `F_PUNCHHOLE` semantics.

## Q8. Agents installed on the development Mac but not yet supported

Research date: 2026-11-23. Every item below was checked on a real install by names, sizes, nesting, mtimes, JSON key paths with value types, SQLite schemas and row counts, and app bundle versions. No transcript, prompt, title or other value was printed. SQLite files were opened with `mode=ro` (and `immutable=1` when the app was quit). Program code (app bundles, extension bundles) was read where docs were silent.

### Takeaway
Two new stores hold real sessions: **Zed's Agent Panel** and **VS Code chat** (Copilot Chat plus the Gemini Code Assist extension). Several other candidates do not hold their own sessions:
- The Codex desktop app (`ChatGPT.app`, bundle id `com.openai.codex`) and Zed's external agents write into stores Domovy already reads.
- `~/.opencode` is an install folder.
- The 1.8 GB in `~/.cursor` is IDE extensions.
- `Claude-3p` and `CampoUIInternal` are not agent session stores.

The main new risk is cross-store references: Zed, VS Code and the Codex extension all keep their own records that point at Codex or Gemini CLI sessions, so deleting a session that Domovy already supports can leave entries behind in those apps.

### Cited Findings

**Zed (Agent Panel)**
- Verified on a real install (Zed 1.29.3, bundle id `dev.zed.Zed`, executable `zed`, plus `cli` at `/usr/local/bin/zed`; 2026-11-23; Zed was not running):
  - Native threads: `~/Library/Application Support/Zed/threads/threads.db` (SQLite, 472 KB, no WAL while quit), with one table, `threads (id TEXT PRIMARY KEY, summary TEXT, updated_at TEXT, data_type TEXT, data BLOB, parent_id TEXT, folder_paths TEXT, folder_paths_order TEXT, created_at TEXT)` and index `threads_list_metadata`. There are 4 rows here. `id` is a 36-character UUID, `updated_at` is ISO 8601 with microseconds and `Z`, and `data_type` is `zstd` on every row. `data` is a zstd-compressed JSON object with the fields `title`, `messages` (an array of `{User: {id, content}}` or `{Agent: …}`), `updated_at`, `detailed_summary`, `initial_project_snapshot {worktree_snapshots [{worktree_path, git_state}], timestamp}`, `cumulative_token_usage`, `request_token_usage`, `model {provider, model}`, `profile`, `subagent_context`, `thinking_enabled`, `thinking_effort`, `draft_prompt`, `ui_scroll_position`, `sandboxed_terminal_temp_dir` (a `$TMPDIR/zed-agent-…` folder, already gone for all 4 threads), `sandbox_grants` and `version` (`0.3.0`). The title and project can be read from the columns `summary` and `folder_paths` without decompressing.
  - Legacy store `threads/threads-db.1.mdb/` (LMDB `data.mdb` + `lock.mdb`, 56 KB, last written 2026-02-28) is no longer written.
  - Sidebar metadata is in the workspace DB `~/Library/Application Support/Zed/db/0-stable/db.sqlite` (WAL: `-wal` was 4.2 MB, `-shm` present). Table `sidebar_threads` is `STRICT` with the columns `thread_id BLOB PK` (16-byte UUID), `session_id`, `agent_id`, `title`, `updated_at`, `created_at`, `folder_paths`, `folder_paths_order`, `archived INTEGER`, `main_worktree_paths`, `main_worktree_paths_order`, `remote_connection`, `interacted_at` and `title_override`. It holds 7 rows here:
    - 4 have `agent_id` NULL (Zed's native agent), and their `session_id` equals a `threads.id` in `threads.db`.
    - 2 have no `session_id` at all.
    - 1 has `agent_id = codex-acp`, and its `session_id` is a Codex thread id that exists in `~/.codex/state_5.sqlite` and `~/.codex/sessions/…/rollout-*.jsonl` (`originator = zed` there).
  - Archive support tables: `archived_git_worktrees (id, worktree_path, main_repo_path, branch_name, staged_commit_hash, unstaged_commit_hash, original_commit_hash)` and `thread_archived_worktrees (thread_id, archived_worktree_id)` (both empty here). `sidebar_terminal_threads` is also empty. `kv_store` holds `agent_panel*` and `dock_panel_size|…:agent_panel` keys, one migration key named `thread-metadata-…-backfill`, and `dismissed-acp-thread-import`.
  - Text threads (the older assistant): `~/.config/zed/conversations/<title> - <n>.zed.json`, 4 files, 16 KB, last written 2025-05. The file name contains the title, so it must not be logged. JSON fields: `id`, `zed`, `version`, `text`, `messages [{id {replica_id, value}, start, metadata {role, status, timestamp}}]`, `summary` and `slash_command_output_sections`. The prompt library is in `~/.config/zed/prompts/prompts-library-db.0.mdb` (LMDB).
  - External agents: `Zed/external_agents/registry/registry.json` (`{version, agents [46 × {id, name, version, distribution {npx {package, args}}, …}], extensions}`) and `registry/npx/codex-acp/` (334 MB, an npm install of the ACP adapter). An ACP agent keeps its sessions in its own store (here, Codex). Zed keeps only the `sidebar_threads` row.
  - Other large folders are not agent data: `copilot/` (437 MB, GitHub Copilot language server for edit predictions), `languages/` (389 MB), `node/` (198 MB), `extensions/` (166 MB), `hang_traces/`.
  - Must never be deleted: `~/.config/zed/settings.json`, `keymap.json`, `tasks.json`, `prompts/`, and the rest of `db.sqlite`. That file is the whole workspace DB (panes, editors, trusted worktrees), so Domovy may at most delete rows in `sidebar_threads`.
- Docs: a permanent delete happens from Thread History via the trash icon: it "removes the thread's conversation history and cleans up any associated worktree data". Deleted threads cannot be recovered. Archiving moves a thread to Thread History. If the thread ran in a linked worktree that no other thread uses, archiving "saves the worktree's Git state and removes it from disk", and restoring brings the worktree back. Since Parallel Agents, a thread must be archived before it can be deleted. Zed does not document a retention limit. — [Zed docs: parallel agents](https://zed.dev/docs/ai/parallel-agents); [agent panel](https://zed.dev/docs/ai/agent-panel); [zed#51458](https://github.com/zed-industries/zed/discussions/51458)

**VS Code chat (GitHub Copilot Chat and other chat participants)**
- Verified on a real install (VS Code 1.138.0 at `/Applications/Programing/Visual Studio Code.app`, bundle id `com.microsoft.VSCode`, executable `Code`; built-in `copilot` extension 0.66.0; 2026-11-23; VS Code was not running). The storage paths below come from the VS Code workbench bundle (`out/vs/workbench/workbench.desktop.main.js`, `ChatSessionStore`):
  - Session files: a chat in a folder or workspace window is stored at `User/workspaceStorage/<workspace id>/chatSessions/<sessionId>.json`. With `chat.useLogSessionStorage` on (the default), the chat is also written as `<sessionId>.jsonl`. A chat in an empty window goes to `User/globalStorage/emptyWindowChatSessions/` instead. Chats moved between workspaces go to `globalStorage/transferredChatSessions/` (`ChatSessionStore.transferIndex`). An older location was `workspaceStorage/no-workspace/chatSessions`.
  - Index: the key `chat.ChatSessionStore.index` in the matching `state.vscdb` `ItemTable` (global or workspace scope) holds `{version: 1, entries: {<sessionId>: {sessionId, title, lastMessageDate (ms), isImported, initialLocation, isEmpty, timing {created, lastRequestEnded}, lastResponseState}}}`. VS Code trims the index to the 400 most recent non-external entries. The trim removes index entries only, not the files. The older key `interactive.sessions` is `[]` here.
  - VS Code's own delete (`internalDeleteSession`) deletes `<id>.json` and `<id>.jsonl`, then removes the index entry and flushes the index. `clearAllSessions` does this for every entry. Edit state is kept per workspace in `workspaceStorage/<id>/chatEditingSessions/<sessionId>/`.
  - On this Mac: one workspace folder (`workspaceStorage/<13-digit id>/`, 56 KB), and no `chatSessions`, `chatEditingSessions` or `emptyWindowChatSessions` folder anywhere. The global index has 1 entry (`isEmpty` false, `initialLocation` panel) with no file behind it, so it is a dangling entry. Domovy must tolerate an index entry without a file, and a file without an index entry.
  - The workspace `state.vscdb` has `agentSessions.model.cache` (`[{providerType, providerLabel, resource, icon, label, status, timing}]`) and `agentSessions.state.cache`. The global DB has `agent-host.db` with `sessions (session_uri PK, provider, start_time, external, registration_source, modified_time)` (0 rows) and `metadata` (`sessionRegistryBackfilled:copilotcli`).
  - Copilot Chat globalStorage `globalStorage/github.copilot-chat/` (43 MB):
    - `commandEmbeddings.json` (19 MB) and `settingEmbeddings.json` (23 MB) are caches that VS Code downloads again.
    - `session-store.db` (+ WAL) has the same schema as the Copilot CLI's: `sessions (id, cwd, repository, host_type, branch, summary, agent_name, agent_description, created_at, updated_at)`, `turns (session_id, turn_index, user_message, assistant_response, timestamp)`, `checkpoints (session_id, checkpoint_number, title, overview, history, work_done, technical_details, important_files, next_steps, created_at)`, `session_files`, `session_refs` and the FTS5 `search_index`. All tables have 0 rows here. This settles the schema Domovy's Copilot CLI adapter assumes.
    - Also present: `copilot.cli.oldGlobalSessions.json` (0 bytes), `copilotCli/` (a `copilot` CLI shim), `vscode-sessions-<uuid>/{diff.index, pathspec.txt}`, `memory-tool/memories/*.md` (user memory, keep), and `{ask,plan,explore}-agent/*.agent.md` (built-in agent definitions, keep).
  - Must never be deleted: `User/settings.json`, `keybindings.json`, `snippets/`, `profiles/`, `sync/`, `chatLanguageModels.json`, `globalStorage/storage.json`, and every other key in `state.vscdb`. Sign-in state sits in the same table (for example `github.copilot-chat-github-read:user …`). `User/History/` (53 MB) is VS Code's local file history, not chat.
- Codex VS Code extension `openai.chatgpt` (26.1007.21434 and 26.908.40401 installed side by side; the Cursor install has it too). Its sessions are Codex threads in `~/.codex` (`originator = codex_vscode`, 84 threads here). It also keeps a 42 KB global-state value under the key `openai.chatgpt` with `persisted-atom-state.prompt-history.<codex thread id>` (typed prompts per thread), `thread-descriptions-v1.<thread id>`, `heartbeat-thread-permissions-by-id.<thread id>` and `composer-prompt-drafts-v1.local:<thread id>`. Deleting a Codex thread leaves these entries, including prompt text, until the extension prunes them. Domovy cannot remove them without writing `state.vscdb`.
- No other agent extensions are installed in VS Code (`~/.vscode/extensions`). The only AI extensions are `anthropic.claude-code` 2.1.270/2.1.296, which writes to `~/.claude`, `openai.chatgpt`, `openai.codex-audio` and `google.geminicodeassist`. There is no Cline, Roo, Kilo, Continue, Augment, Amazon Q, Codeium/Windsurf, Cody or Tabnine. No globalStorage folder exists for any of them.
- Third-party confirmation of the layout: [microsoft/vscode#305818](https://github.com/microsoft/vscode/issues/305818); [chasm-cli storage.rs](https://docs.rs/crate/chasm-cli/2.0.0/source/src/storage.rs)

**Gemini Code Assist (VS Code extension `google.geminicodeassist`)**
- Verified on a real install (extension 2.100.0 and 2.104.0, 2026-11-23):
  - Chats are not files. They live in VS Code extension global state: the `state.vscdb` key `google.geminicodeassist` (9.8 MB, nearly all of it the inner key `geminiCodeAssist.chatThreads`, the extension's `MementoKey.CHAT_THREADS`). The shape is `{<20-char scope key>: {<thread uuid>: {id, title, create_time, update_time, ideContextFileUris, ideContextFolderUris, additionalContext, a2aTaskId, history [{entity, markdownText, ideContext, chatSectionId}], version, selectedModelConfigId}}}`, with 3 threads here. The full chat text is inline.
  - File checkpoints: `globalStorage/google.geminicodeassist/chat_checkpoint_files/<16-hex trace id>/<hex>` (4 files, 2026-07-09, `CHAT_CHECKPOINTS_STORAGE_PATH`). The extension prunes checkpoint folders that no thread references.
  - Agent mode runs Gemini CLI's a2a server, shipped as `agent/a2a-server.mjs` in the extension. Its chats go to Gemini CLI's own store `~/.gemini/tmp/<project>/chats/session-…-a2a-serv.jsonl`. These are the 427 a2a chats with one shared session id noted in the Gemini section above. A thread's `a2aTaskId` links the two.
  - `~/Library/Application Support/cloud-code/`: `cloudcode_cli/cloudcode_cli/<8-hex>/cloudcode_cli` (an 89 MB binary), `citations.log`, `install_id.txt`. `~/Library/Application Support/google-vscode-extension/auth/{credentials.json, application_default_credentials.json}` are sign-in files and must never be deleted.
- Docs: chats are deleted from "Resume Previous Chat" via the delete control. The limit is 20 chats, and the oldest is deleted automatically. A single prompt and response pair can also be deleted. — [Gemini Code Assist: use chat](https://developers.google.com/gemini-code-assist/docs/use-gemini-code-assist-chat); [chat with Gemini Code Assist](https://developers.google.com/gemini-code-assist/docs/chat-gemini)

**Codex desktop app**
- Verified on a real install (2026-11-23):
  - `/Applications/ChatGPT.app` has bundle id `com.openai.codex`, version 26.1111.71704 and executable `ChatGPT`. It embeds `Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex` (codex-cli 0.169.1; Homebrew `codex` is 0.169.0) and runs it as `codex app-server --listen stdio://`. Its helpers are `cua_node/bin/node` and `node_repl`.
  - The app uses the same `~/.codex` store Domovy already supports: the running `app-server` held `~/.codex/logs_2.sqlite` and `queue_1.sqlite` open. In `state_5.sqlite` `threads`, the columns `originator` and `thread_source` tell sources apart: `codex_work_desktop` (app, 12), `codex_vscode` (extension, 84), `codex-tui` (CLI, 70), `zed` (ACP, 1). The column `source` is `cli`, `vscode` or a JSON `{"subagent": …}`. Newer columns are `name`, `is_pinned`, `thread_section_id`, `section_position`, `project_id`, `daybreak_enabled`, `creator_user_id`, `creator_account_id` and `attached_thread_parent_id` (no pinned or sectioned threads here).
  - `~/Library/Application Support/Codex/` (268 MB) is the app's embedded Chromium browser profile: `Default/`, `codex-browser-app/`, `component_crx_cache/`, `CertificateRevocation/`, `WasmTtsEngine/`, `Crashpad/`, `sentry/`. It also holds `executor-plugins/codex-app-tools/` (an MCP plugin), an empty `artifact-sessions/{store, runtime-generations}`, and `browser-sidebar-page-states.json` (`{pages: {"browser:<uuid>": {browserTabId, conversationId, page {title, url, navigation, updatedAt, …}}}}`). Neither of the two `conversationId`s here is a local Codex thread id. `~/Library/Application Support/com.openai.codex/` holds only `production-appcast-bootstrap.json`, and `~/Library/Caches/com.openai.codex` is 912 KB (Sparkle).
  - When this was checked, `codex app-server` and six `node_repl` helpers were running while the main `ChatGPT` process was not. Domovy's Codex live check must match `CodexCLI.app/…/codex` and `app-server`, not only `ChatGPT`.

**Cursor (beyond what the adapter covers)**
- Verified on a real install (2026-11-23). `~/.cursor` is 1.8 GB, and nearly all of it is `extensions/` (60 VS Code extensions installed into Cursor). Cursor.app itself is gone, so these are leftovers. They are not chat data.
  - `ai-tracking/ai-code-tracking.db` has `ai_code_hashes (hash, source, fileExtension, fileName, requestId, conversationId, timestamp, createdAt)` (0 rows), `scored_commits` and `tracking_state`. `conversationId` refers to a chat, so a delete would leave rows here.
  - Also present: `projects/<p>/{agent-tools, rules, terminals}` (28 KB), `argv.json`, `cli-config.json`, `ide_state.json`, `mcp.json`.
  - There is no `chats/` folder and no `worktrees/` folder.
  - The Cursor agent CLI is installed: `~/.local/bin/cursor-agent` links to `~/.local/share/cursor-agent/versions/2025.10.01-369e3d0/cursor-agent` (137 MB of versions). It has never written `~/.cursor/chats` here.
  - Domovy's Cursor adapter covers `state.vscdb` chats, `~/.cursor/chats`, `projects/*/agent-transcripts` and the CLI process. It reports the rest of `~/.cursor` as "keep". It does not cover `ai-tracking`, `extensions/` (left by an uninstalled app), `worktrees/` or old `cursor-agent` versions.

**OpenCode install folder**
- Verified on a real install (2026-11-23): `~/.opencode` (199 MB) is an install folder. It holds `bin/opencode` (138 MB, Mach-O arm64), `node_modules/` (61 MB: `@opencode-ai/*`, `@ai-sdk/*`, `effect`, …), `package.json` and `package-lock.json`. It holds no sessions. Domovy's OpenCode adapter correctly reads `~/.local/share/opencode/opencode.db` (1 MB). `~/.config/opencode` is 61 MB (plugins under `node_modules`) and `~/.cache/opencode` is 4.4 MB. All three must be kept.

**Not agent session stores**
- `~/Library/Application Support/Claude-3p/`: Claude Desktop's third-party-inference (Bedrock, Vertex, Foundry, gateway) profile. Here it holds only `claude_desktop_config.json` `{enterpriseConfig: {}, _cfprefsMigrated: bool}`. The docs place `configLibrary/` under it. It is configuration and must be kept. If 3P mode is used, its sessions presumably sit under this folder in the same layout as `Claude/`; this is not verified. — [Claude Desktop on 3P](https://www.claude.com/docs/third-party/claude-desktop/overview); [configuration format](https://claude.com/docs/third-party/claude-desktop/configuration-format.md)
- `~/Library/Application Support/CampoUIInternal/SlidingHashedChatIDs.json` (an array of 6 strings): written by Apple's private `CampoUIInternal.framework` (with `CampoServices`, `CampoUIServices` and the `CampoRemoteService` XPC service), with preferences `com.apple.campo` (`ResumableConversation_chatID`, `campo.unsentMessages`, …). This is macOS's own chat feature, not a coding agent. Out of scope; never touch.
- `/Applications/Copilot.app` is Microsoft Copilot (`com.microsoft.copilot-mac` 25.7.441030001), a consumer chat app, not GitHub Copilot CLI. There is still no `~/.copilot` folder.
- `~/Applications/Herdr.app` (`dev.herdr.app` 0.1.7, config in `~/.config/herdr-app/`) and `com.openai.chat` / `com.openai.atlas` (ChatGPT classic and Atlas) were seen but not examined.

### Inferences
- Zed session unit: one `sidebar_threads` row, plus for native threads the `threads.db` row with the same id. A thread with `agent_id` set belongs to that agent's store, so Domovy should show it under the owning adapter (Codex, Claude Code) with a "listed in Zed" note. Deleting one of those means removing the agent's session and, optionally, the Zed row. Deleting natively means removing the `threads.db` row and the `sidebar_threads` row, plus `thread_archived_worktrees` and orphaned `archived_git_worktrees` rows. It needs Zed quit (rule 4) and a backup of both DBs. Archiving: Zed's own archive is the `archived` flag, so Domovy could either set it (a DB write, Zed quit) or export the decompressed thread JSON and keep the row. Zed has no CLI for threads, so editing the files is the only option. `updated_at` is a column, not an mtime, so rule 5 is about leaving the DB files' mtimes alone.
- VS Code chat session unit: `<sessionId>.json` + `.jsonl` in the index's storage root, plus the `chatEditingSessions/<sessionId>/` folder and the index entry. Moving the files to the Trash is safe while VS Code is quit. Removing the index entry is a `state.vscdb` write and needs the same quit, backup and read-only fallback Domovy uses for Cursor. Without the index edit, VS Code keeps a dangling history entry, which it already tolerates.
- Gemini Code Assist session unit: one thread inside the `google.geminicodeassist` JSON value. Deleting means rewriting a 9.8 MB JSON blob in `state.vscdb`, so it should stay read-only (list and size only) until Domovy has a tested VS Code writer. Point users to the extension's own delete instead. Its agent-mode chats are already deletable through the Gemini CLI adapter.
- Several apps keep their own records that point at sessions Domovy can already delete: Zed's `sidebar_threads` (Codex and Claude via ACP), the `openai.chatgpt` extension state (prompt history keyed by Codex thread id), Gemini Code Assist's `a2aTaskId`, and VS Code's `agent-host.db` (Copilot CLI). A delete plan for a Codex or Gemini session should list these as entries it leaves behind.

### Gaps
- Not verified: the JSON shape inside VS Code `chatSessions/*.json(l)`, because no such file exists here. The format needs a fixture built from an install that has chats.
- Not verified: what Zed's delete does to an ACP thread's session in the external agent's store, and how `archived_git_worktrees` commits are kept alive (refs vs. dangling objects).
- Not verified: Gemini Code Assist's 20-chat cap against the stored data (3 threads here), and what the 20-character scope key means.
- Not verified: where Claude Desktop 3P mode stores sessions.

## Q9. Agents not installed on the development Mac (from source, not verified on a real install)

Research date: 2026-11-23. Every finding here comes from reading source code at the commit named, or from docs. None of the agents is installed on this Mac. Before an adapter relies on any of it, re-verify it against a real install and build a fixture from that install. "[3P]" marks a third-party parser or community source. Source repos were shallow-cloned and only read (nothing was built or run).

### Takeaway
- Qwen Code is a Gemini CLI fork, but its storage now looks like Claude Code: one JSONL per session under `~/.qwen/projects/<cwd slug>/chats/`. It has sidecar files, a native `chats/archive/` folder, a live-session registry and per-session writer locks. It has no CLI delete command.
- Agents with a scriptable delete of their own:
  - Crush: `crush session rm`
  - Kilo: `kilo session delete`
  - Cline: `cline history delete`
  - Kiro CLI: `kiro-cli chat --delete-session`
  - Amp: `amp threads delete|archive`, which acts on the server
- Agents that are plain files Domovy can move: Kimi, Roo Code, Continue, Auggie, Factory Droid and Aider.
- Read-only:
  - Windsurf and Trae: encrypted.
  - Warp and Amazon Q: the live database of a running app; Amazon Q also stores auth in the same DB.
  - Junie and the Kiro IDE: layout undocumented or recently changed.
  - iFlow: the service shut down.

### Cited Findings

**Qwen Code (`QwenLM/qwen-code` @ `09b8135e`, CLI 0.28.3)**
- Root and overrides:
  - Global dir is `~/.qwen`; `QWEN_HOME` replaces it. — [storage.ts#L193-L203](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/config/storage.ts#L193-L203)
  - Session data goes under the "runtime base dir". By default that is the global dir; `QWEN_RUNTIME_DIR` overrides it. — [storage.ts#L169-L191](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/config/storage.ts#L169-L191)
- Project directory: `<runtime>/projects/<slug>/`. The slug is the project root with every non-alphanumeric character replaced by `-`, the same scheme as Claude Code, but with no truncation or hash. — [storage.ts#L619-L623](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/config/storage.ts#L619-L623), [paths.ts#L388-L392](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/utils/paths.ts#L388-L392)
- The temp directory still uses a SHA-256 of the project root: `<runtime>/tmp/<sha256>/` holds `tool-results/`, `checkpoints/` and `shell_history`. Code comments still say chats live in `~/.qwen/tmp/<project_id>/chats/`; that is out of date. — [storage.ts#L625-L634](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/config/storage.ts#L625-L634)
- Transcript:
  - File: `projects/<slug>/chats/<sessionId>.jsonl`, created exclusively with `wx` and append-only. The file name must match `^[0-9a-fA-F-]{32,36}\.jsonl$`. — [chatRecordingService.ts#L1511-L1531](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/chatRecordingService.ts#L1511-L1531), [sessionService.ts#L547](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/sessionService.ts#L547)
  - Each record has `uuid`, `parentUuid`, `sessionId`, `timestamp` (ISO), `type` (`user|assistant|tool_result|system`) and an optional `subtype`, plus `cwd`, `version`, `gitBranch` and `model`.
  - The title is a `system` record with `subtype: custom_title` (with `titleSource` `manual|auto`).
  - Subtypes `parent_session` and `session_source` link forks and subagent sessions. — [chatRecordingService.ts#L431-L470](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/chatRecordingService.ts#L431-L470)
- Per-session sidecars next to the transcript, in the same folder:
  - `.title.json` (`{displayName, source, updatedAt}`, a list label)
  - `.artifacts.json`
  - `.branch.json`
  - `.goal.json`
  - `.pr.json`
  - `.worktree.json`
  - `.ledger.jsonl`
  - `.runtime.json`
  — [sessionService.ts#L1035-L1110](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/sessionService.ts#L1035-L1110), [#L1210-L1218](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/sessionService.ts#L1210-L1218), [storage.ts#L726-L740](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/config/storage.ts#L726-L740)
- Archive is native: archived sessions, with all their sidecars, move to `chats/archive/`, which has the same layout. — [sessionService.ts#L1039-L1047](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/sessionService.ts#L1039-L1047)
- Other per-session data:
  - `projects/<slug>/subagents/<sessionId>/` (subagent JSONL transcripts) — [agent-transcript.ts#L66-L80](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/agents/agent-transcript.ts#L66-L80)
  - `~/.qwen/file-history/<sessionId>/`
  - `<runtime>/resources/<sessionId>/`
  - artifact snapshots under `<runtime>/artifacts/snapshots/`
  - a per-project `projects/<slug>/session-organization.v1.json`, which records list grouping and pins
- Qwen's own delete is `SessionService.removeSession`. Under a writer lease, it unlinks the transcript (active or archived) and the session's artifact snapshots. It then removes:
  - the worktree, PR, goal, title, branch and artifact-summary sidecars
  - the prompt ledgers
  - `file-history/<id>`
  - `resources/<id>`
  - the entry in `session-organization`
  Reading the code, it does not remove `subagents/<id>/`. — [sessionService.ts#L4201-L4210](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/sessionService.ts#L4201-L4210), [#L4577-L4620](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/sessionService.ts#L4577-L4620)
- Commands:
  - `qwen sessions list [--json] [--limit N]` lists the current project's sessions, one JSON per line with `sessionId`, `cwd`, `startTime`, `mtime`, `prompt`, `gitBranch`, `filePath`, `messageCount` and `customTitle`.
  - `qwen sessions ps` lists running sessions. — [commands/sessions.ts#L13-L20](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/cli/src/commands/sessions.ts#L13-L20)
  - There is no CLI delete. Delete exists only as the interactive `/delete`, which refuses the current session, and through the `qwen serve` HTTP API. — [useDeleteCommand.ts#L90-L104](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/cli/src/ui/hooks/useDeleteCommand.ts#L90-L104)
- Liveness:
  - Each running top-level session writes `~/.qwen/sessions/<pid>.json` (or `<pid>-<8hex>.json` for an ACP host). The fields are `pid`, `procStart`, `sessionId`, `cwd`, `name`, `startedAt` and `qwenVersion`. The session removes the file on exit. Records that fail the pid plus start-token check are stale. — [session-registry.ts#L8-L60](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/session-registry.ts#L8-L60)
  - Writers hold `<runtime>/tmp/session-writer-locks/<id>.lock`. — [session-writer-lease.ts#L1709-L1719](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/services/session-writer-lease.ts#L1709-L1719)
  - `.runtime.json` is never deleted, so it says nothing about liveness.
- Retention: no session retention setting was found (unlike Gemini CLI's `sessionRetention`). Only overflow tool results older than 24 h are swept at startup and on `/clear`. — [client.ts#L1009-L1010](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/core/client.ts#L1009-L1010)
- Never delete:
  - `settings.json`
  - `oauth_creds.json`
  - `mcp-oauth-tokens.json`
  - `google_accounts.json`
  - `installation_id`
  - `memory.md`
  - `commands/`, `skills/`, `extensions/`, `workflows/`, `bin/`
  - `projects/<slug>/memory/`
  - the project's `.qwen/`
  — [storage.ts#L15-L24, L205-L226](https://github.com/QwenLM/qwen-code/blob/09b8135e6929df2e7f6a5cee8e55c47980b5f92e/packages/core/src/config/storage.ts#L205-L226)

**Kiro (AWS)**
- Kiro CLI has several formats, by version [3P, kiro-cli-history README]:
  - CLI 3.0: `~/.kiro/sessions/<workspace-hash>/sess_<id>/`, holding `session.json` (title, `workspacePaths`, `modelId`), `messages.jsonl`, `publish.cursor` and `snapshots/`.
  - CLI 2.x classic: `~/.kiro/sessions/cli/<id>.jsonl` plus `<id>.json`.
  - CLI 2.x TUI and 1.x: `~/Library/Application Support/kiro-cli/data.sqlite3`.
  - `KIRO_HOME` moves `~/.kiro`.
  — [pypi kiro-cli-history](https://pypi.org/project/kiro-cli-history/)
- Official commands: `kiro-cli chat --list-sessions [--all-cwds]`, `kiro-cli chat --delete-session <ID>` (permanent, refuses a session active elsewhere), and `/sessions clean`. — [Kiro docs: session management](https://kiro.dev/docs/cli/chat/session-management/)
- Kiro IDE stores sessions under `~/Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/<workspace-hash>/`. The format changed around February 2026, from `.chat` JSON to index files plus execution files [3P]. One user report shows this folder at 13 GB. — [kirodotdev/Kiro#5469](https://github.com/kirodotdev/Kiro/issues/5469)
- Amazon Q Developer CLI (`aws/amazon-q-developer-cli` @ `15cc8f3c`, maintenance only, replaced by Kiro CLI):
  - Storage: `~/Library/Application Support/amazon-q/data.sqlite3`.
  - Table `conversations(key = absolute cwd, value = JSON)` keeps one conversation per directory.
  - The same DB holds auth in `state` and `auth_kv`.
  — [paths.rs#L327-L332](https://github.com/aws/amazon-q-developer-cli/blob/15cc8f3cd18c4272925ce1c7053268eedff1ea0a/crates/chat-cli/src/util/paths.rs#L327-L332), [007_conversations_table.sql](https://github.com/aws/amazon-q-developer-cli/blob/15cc8f3cd18c4272925ce1c7053268eedff1ea0a/crates/chat-cli/src/database/sqlite_migrations/007_conversations_table.sql#L1-L4)

**Crush (`charmbracelet/crush` @ `ee51fe87`)**
- Storage is one SQLite DB per project, `<project>/.crush/crush.db`, in WAL mode with `foreign_keys=ON`.
  - `sessions` columns: `id`, `parent_session_id`, `title`, `message_count`, `created_at` and `updated_at` (unix seconds).
  - `messages` and `files` cascade on delete. Child sessions (`parent_session_id`) do not.
  - There is no cwd column; the project is the folder that holds the DB.
- `~/.local/share/crush/projects.json` (`{projects:[{path, data_dir, last_accessed}]}`) is the only global list of these DBs. That folder is `~/.local/share` on macOS too.
- Own commands: `crush session list --json`, `crush session rm <id>`, `-D <data-dir>`. `crush.lock` holds `{pid, version, started_at}`, but only in server mode.
- Keep `~/.local/share/crush/crush.json` (OAuth tokens) and `~/.config/crush/`.
— [connect.go#L19-L29](https://github.com/charmbracelet/crush/blob/ee51fe87bb306a945bf9057edf94f5574b192fd2/internal/db/connect.go#L19-L29), [load.go#L1407-L1427](https://github.com/charmbracelet/crush/blob/ee51fe87bb306a945bf9057edf94f5574b192fd2/internal/config/load.go#L1407-L1427), [initial.sql](https://github.com/charmbracelet/crush/blob/ee51fe87bb306a945bf9057edf94f5574b192fd2/internal/db/migrations/20250424200609_initial.sql#L4-L60)

**Goose (`block/goose` @ `059fee25`)**
- Location: the code uses the XDG strategy on macOS, so data is in `~/.local/share/goose/sessions/sessions.db`. The docs and a code comment instead say `~/Library/Application Support/Block/goose/`; check both. `GOOSE_PATH_ROOT` overrides it. Before v1.10.0, sessions were `.jsonl` files.
- `sessions` has `name`, `working_dir`, `created_at`, `updated_at`, `archived_at` (native archive) and `parent_session_id`.
- `messages` does not cascade. Goose's own delete runs one transaction: messages, then `usage_ledger`, then tags, then the session.
- `goose session list -f json` works. `goose session remove --session-id <id>` always asks for confirmation on a TTY.
- Keep `~/.config/goose/` (`config.yaml`, `secrets.yaml`).
— [paths.rs#L8-L38](https://github.com/block/goose/blob/059fee25f13fa92be561a7d42cdd04ececef5a98/crates/goose/src/config/paths.rs#L8-L38), [session_manager.rs#L2598-L2633](https://github.com/block/goose/blob/059fee25f13fa92be561a7d42cdd04ececef5a98/crates/goose/src/session/session_manager.rs#L2598-L2633), [cli.rs#L519-L559](https://github.com/block/goose/blob/059fee25f13fa92be561a7d42cdd04ececef5a98/crates/goose-cli/src/cli.rs#L519-L559)

**Aider (`Aider-AI/aider` @ `5dc9490b`)**
- Aider has no session concept and no index. Files per repo, in the git root or cwd:
  - `.aider.chat.history.md`: appended by every run, each run starting with `# aider chat started at <time>`.
  - `.aider.input.history`
  - `.aider.tags.cache.v3/` or `v4/`: a rebuildable cache.
  - Paths can be changed with `--chat-history-file` and `--input-history-file`, or `AIDER_*` environment variables.
- `~/.aider/oauth-keys.env` is a credential.
— [args.py#L270-L288](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/args.py#L270-L288), [repomap.py#L35-L43](https://github.com/Aider-AI/aider/blob/5dc9490bb35f9729ef2c95d00a19ccd30c26339c/aider/repomap.py#L35-L43)

**Cline (`cline/cline` @ `34c104e6`)**
- Cline is now built on an SDK, and the VS Code extension, the CLI and JetBrains share `~/.cline` (`CLINE_DIR` or `CLINE_DATA_DIR` override it).
- Index: SQLite `~/.cline/data/db/sessions.db`, table `sessions`, with `session_id`, `pid`, `status`, `started_at`, `ended_at`, `cwd`, `prompt`, `metadata_json` (title), `messages_path` and `parent_session_id`.
- Session data: `~/.cline/data/sessions/<id>/` with `<id>.messages.json`, `<id>.json` and `<id>.compaction.json`.
- Checkpoints are git refs in the user's repo (`refs/cline/checkpoints/<id>/*`).
- Legacy layout: `<root>/state/taskHistory.json` plus `tasks/<id>/`, where `<root>` is `~/.cline/data` or `globalStorage/saoudrizwan.claude-dev`.
- Own delete: `cline history delete --session-id <id>`. Keep `secrets.json`, `globalState.json`, `settings/`.
— [paths.ts#L186-L254](https://github.com/cline/cline/blob/34c104e6fc49781cda4adcd73ffdccd8f029fef9/sdk/packages/shared/src/storage/paths.ts#L186-L254), [persistence-service.ts#L586-L640](https://github.com/cline/cline/blob/34c104e6fc49781cda4adcd73ffdccd8f029fef9/sdk/packages/core/src/session/services/persistence-service.ts#L586-L640)

**Roo Code (`RooCodeInc/Roo-Code` @ `b867ec91`, last commit 2026-05-15)**
- Session folders: `~/Library/Application Support/<Code|Cursor|Windsurf|VSCodium>/User/globalStorage/rooveterinaryinc.roo-cline/tasks/<id>/`. Each holds `api_conversation_history.json`, `ui_messages.json`, `task_metadata.json` and `history_item.json` (`task` title, `ts`, `workspace`, `childIds`, `size`).
- `tasks/_index.json` is a cache that gets reconciled.
- Roo also mirrors `taskHistory` into VS Code `state.vscdb`, but only as a fallback.
- Checkpoints: a shadow repo `checkpoints/<sha256(cwd)[:8]>/` with branch `roo-<id>`.
- Own delete: removes the task from the history, then the branch, then `rm -rf tasks/<id>`.
— [ClineProvider.ts#L1737-L1803](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/core/webview/ClineProvider.ts#L1737-L1803), [TaskHistoryStore.ts#L20-L30](https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/src/core/task-persistence/TaskHistoryStore.ts#L20-L30)

**Kilo Code (`Kilo-Org/kilocode` @ `bfdec549`)**
- Kilo is now an OpenCode fork. The extension starts `kilo serve`.
- Storage: `~/.local/share/kilo/kilo.db` (`KILO_DB` overrides it), with the same `session`, `message` and `part` tables as OpenCode, including `time_archived`. Config is in `~/.config/kilo/`, auth in `auth.json`.
- Own delete: `kilo session delete <id>`.
- Legacy Kilo (a Roo fork) kept `taskHistory` only in VS Code `state.vscdb`.
— [global.ts#L12-L26](https://github.com/Kilo-Org/kilocode/blob/bfdec5496922452222223c01b4cc6c89305b0279/packages/core/src/global.ts#L12-L26), [cmd/session.ts#L55-L69](https://github.com/Kilo-Org/kilocode/blob/bfdec5496922452222223c01b4cc6c89305b0279/packages/opencode/src/cli/cmd/session.ts#L55-L69)

**Continue (`continuedev/continue` @ `5522c6f4`)**
- Sessions: `~/.continue/sessions/<id>.json`, indexed by `sessions/sessions.json` (`[{sessionId, title, dateCreated, workspaceDirectory, messageCount}]`). `CONTINUE_GLOBAL_DIR` overrides the root.
- Own delete: unlinks the file and rewrites the index, with no locking.
- Keep `config.yaml`, `config.json` and `.env`.
— [paths.ts#L78-L112](https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/util/paths.ts#L78-L112), [history.ts#L60-L85](https://github.com/continuedev/continue/blob/5522c6f44ca0ac3528b37244818fbfa39b5af470/core/util/history.ts#L60-L85)

**Kimi CLI (`MoonshotAI/kimi-cli` @ `9ab1286b`)**
- Root: `~/.kimi/` (`KIMI_SHARE_DIR` overrides it).
- `kimi.json` lists `work_dirs[{path, last_session_id}]`.
- Session folder: `sessions/<md5(workdir)>/<id>/`, holding `context.jsonl`, `wire.jsonl` and `state.json` (`custom_title`, `archived`, `archived_at`).
- Kimi's own delete is `rmtree` of the folder. Archive is a flag. The web UI auto-archives after 15 days.
- Keep `credentials/`, `config.toml`, `mcp.json`.
— [metadata.py#L17-L40](https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/metadata.py#L17-L40), [web/store/sessions.py#L183-L193](https://github.com/MoonshotAI/kimi-cli/blob/9ab1286b8fe4e6bcd116949a27ce5e0ac3389c82/src/kimi_cli/web/store/sessions.py#L183-L193)

**Other agents (briefly)**
- Amp: threads are stored on the server. Commands: `amp threads list|archive|delete`. The local `~/.local/share/amp/threads/T-<uuid>.json` looks like a cache [3P]. Keep `secrets.json`. — [Amp docs: threads](https://ampcode.com/docs/threads)
- Factory Droid: `~/.factory/sessions/<cwd-slug>/<uuid>.jsonl` plus `<uuid>.settings.json`, Claude-Code-like [3P]. Sessions may also sync to the cloud (`cloudSessionSync`). No local delete command was found. — [Factory docs: settings](https://docs.factory.ai/factory-app/settings)
- Auggie (Augment CLI v1.2.2, read from the shipped npm bundle):
  - Sessions: `~/.augment/sessions-v2/--<cwd slug>--/<id>.jsonl`. The first line is `{type:"session", id, timestamp, cwd}`.
  - Legacy sessions are in `~/.augment/sessions/`.
  - `auggie session list --json` works. Keep `session.json` (auth) and `settings.json`.
  — [Augment CLI reference](https://docs.augmentcode.com/cli/reference)
- Windsurf / Devin Desktop:
  - `~/.codeium/windsurf/cascade/*.pb` hold conversations, reportedly encrypted per conversation [3P].
  - `memories/` holds memories, and `memories/global_rules.md` is written by the user.
  — [Windsurf docs: memories](https://docs.windsurf.com/windsurf/cascade/memories)
- Warp: the agent conversations live in Warp's main app DB [3P], which also syncs to the cloud:
  - Path: `~/Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable/warp.sqlite`.
  - Tables: `agent_conversations`, `ai_queries`.
  — [Warp docs: agent conversations](https://docs.warp.dev/agents/cli/agent-conversations.md)
- Junie CLI:
  - Home: `~/.junie` holds `settings.json` and `trust/`.
  - Each session has `events.jsonl`, `transcript.md` and `subagents/`. The exact folder is not documented.
  - Full context is kept for only the last 10 sessions.
  - The IDE plugin's storage is undocumented.
  — [Junie CLI docs](https://junie.jetbrains.com/docs/junie-cli.html)
- Trae: `~/Library/Application Support/Trae CN/ModularData/ai-agent/database.db`, an SQLCipher-style encrypted SQLite [3P]. No export or delete command. — [xitula/trae-session-export](https://github.com/xitula/trae-session-export)
- Grok CLI: the community `superagent-ai/grok-cli` (`grok-dev`) stores everything in `~/.grok/grok.db`. Its `sessions` table has `title`, `cwd_at_start`, `status` (`active|archived`) and timestamps, and child tables cascade. Keep `user-settings.json` and especially `wallet.json`. xAI's official "Grok Build" also installs a `grok` binary, and its storage is unknown. — [db.ts#L23-L40](https://github.com/superagent-ai/grok-cli/blob/fb97af83f06dca873281d60168430f06c8de6324/src/storage/db.ts#L23-L40), [migrations.ts#L28-L62](https://github.com/superagent-ai/grok-cli/blob/fb97af83f06dca873281d60168430f06c8de6324/src/storage/migrations.ts#L28-L62)
- iFlow CLI: shut down on 2026-04-17 (per the README). It was a Gemini fork with `~/.iflow/{settings.json, tmp/<hash>/, snapshots/<hash>, cache/<hash>/checkpoints}`. The transcript format is undocumented. — [iflow-cli README](https://github.com/iflow-ai/iflow-cli/blob/4642808afbc6580ac117d930f6c64ac0d84955c7/README.md#L1-L2)

### Inferences
- Qwen Code adapter:
  - Session key: (slug, sessionId).
  - Delete plan: the transcript plus every sidecar listed above, `subagents/<id>/`, `file-history/<id>/` and `resources/<id>/`, all moved to the Trash.
  - Archive plan: move the transcript and its sidecars into `chats/archive/` with mtimes kept. Qwen itself then shows the session as archived.
  - Refuse while a live `sessions/<pid>.json` names the session, or while its writer lock or file handles are held.
  - Never touch `session-organization.v1.json`, because that is an edit to an index file. A dangling entry there is harmless; verify this.
  - Because the slug is lossy, take the real cwd from the records' `cwd` field.
- Crush, Kilo and Cline can follow the "agent's own command" rule exactly. Crush needs a second pass for child sessions.
- Goose's delete prompts for confirmation, so it cannot be scripted. Direct DB edits would need Goose quit and a backup.
- Kimi and Roo Code have native archive or delete semantics that are plain file operations, so they are cheap to support.
- Aider is "one file per repo". Discovering it means scanning project folders, so it can only work for folders Domovy already knows about from other agents.
- Suggested order, by popularity and ease:
  1. Qwen Code
  2. Kilo, which reuses the OpenCode adapter
  3. Cline
  4. Crush
  5. Roo Code
  6. Kimi
  7. Continue
  8. Goose
  9. Kiro CLI
  10. Auggie, Factory and Aider
  11. Read-only for the rest

### Gaps
- Nothing in this section was verified on a real install.
- Qwen:
  - Whether `removeSession` really leaves `subagents/<id>/`.
  - Whether older Qwen versions (Gemini-style `~/.qwen/tmp/<sha256>/chats/`) are still read or migrated.
  - What `QWEN_RUNTIME_DIR` does to `file-history`.
- Goose: which macOS data path is real.
- Kiro: the CLI 3.0 layout comes from one third-party README. The official docs only say "SQLite in `~/.kiro/`".
- Factory, Auggie, Warp, Trae and Amp: local layouts rest on third-party parsers or bundle greps.
- Junie IDE plugin and xAI Grok Build: storage unknown.

### Adapter notes (2026-11-23)
Added from the source clones above (each fixture README in `Tests/Fixtures/<agent>/` cites file and line):
- Qwen Code: archive in Qwen's sense, `chats/archive/` renames without `.runtime.json`
  (sessionService.ts#L2198-L2310). `removeSession` does not delete `.runtime.json` or `subagents/<id>/`;
  Domovy's delete moves both. The legacy `tmp/<sha256>/chats/` is not read by 0.28 (no reader or migration);
  Domovy only measures it. `QWEN_RUNTIME_DIR` is not followed.
- Kimi CLI: no lock or pid file for a running session; the only signals are open files and a running
  `kimi`. Its archive flag is only read. `kimi.json` `last_session_id` is not cleared by Domovy.
- Roo Code: `tasks/_index.json` and the `state.vscdb` mirror reconcile themselves when a folder goes
  (TaskHistoryStore.ts#L244-L290, ClineProvider.ts#L2285-L2300). `customStoragePath` is not followed.
- Crush: `crush session delete` leaves child sessions (`title-<id>`, sub-agent tasks), so Domovy runs it for
  each child first. The CLI migrates the database on open; Domovy snapshots it first.
- Cline: `cline history delete` also deletes `refs/cline/checkpoints/<id>` in the project's git repository,
  which Domovy cannot undo; the plan says so. A `messages_path` outside `sessions/<id>/` is refused.
- Kilo Code: same tables as OpenCode; the OpenCode adapter runs with Kilo's flavor and pins `KILO_DB`.
- Continue: the list `sessions.json` is rewritten on every save, so Domovy cuts its entry only while VS Code,
  Cursor, `cn` and `continue-binary` are quit.

### Adapter notes, last batch (2026-11-23)
Each fixture README in `Tests/Fixtures/<agent>/` cites file and line (or bundle function):
- Auggie: full. The npm bundle `@augmentcode/auggie@1.2.2` is a fork of pi's coding agent. A session is
  `sessions-v2/--<slug>--/<id>.jsonl` with header `{type: session, version: 3, id, cwd}` and `<id>.files/` for
  pasted images; Auggie's own delete (picker only) runs `trash` then removes `<id>.files/`. Domovy moves both;
  archive compresses. No lock or pid file; open files and a running `auggie` refuse. A header version above 3 or
  a file not named after its id makes it read-only. Legacy `sessions/` is measured only.
- Factory Droid: full, from Factory's own `session-navigation` skill (factory-plugins, removed 2026-10-24) and a
  third-party reader checked against droid 0.126.0. Delete moves `<uuid>.jsonl` and `<uuid>.settings.json`; the
  plan says a cloud-synced copy is not deleted. Gate: the first record is `session_start` with the file's id.
- Aider: full. Repositories come from the project paths of every other adapter's sessions, `~/.claude.json`
  `projects`, and search folders (`DOMOVY_AIDER_ROOTS`, `agents.aider.searchFolders` in `<Domovy folder>/settings.json`, which replaced `aider-search-roots.txt`; each checked
  with its direct subfolders); a known path is also checked at its git root. Nothing else is crawled. Delete
  moves the two history files and the tag caches; the plan's scope is the repository folder. Custom
  `--chat-history-file` paths are not found. Gate: the history's first line is Aider's run header.
- Grok CLI (community `grok-dev`): full delete, no archive. It has no delete command, so Domovy deletes the
  session's rows (tool results, tool calls, usage, compactions, messages, session) with Grok quit, after a clone
  and with an integrity check, like Cursor. Gate: the tables and columns of migrations.ts and `user_version` 1-3;
  a `~/.grok` without `grok.db` (xAI's Grok Build) is read-only. `wallet.json` is never touched.
- Goose: read-only listing from both `~/.local/share/goose` and `~/Library/Application Support/Block/goose`
  (which one Goose uses on macOS is still unverified); its delete prompts.
- Kiro: read-only. Kiro's docs say "SQLite in ~/.kiro" and a third-party reader says session folders, so Domovy
  lists the CLI 3.0 and 2.x folders it can read and never runs `kiro-cli chat --delete-session` (permanent, and
  Domovy could not keep a copy of what it removes). IDE `kiro.kiroagent` and `kiro-cli/data.sqlite3` are measured.
- Amazon Q CLI: read-only listing of `conversations`; the database also holds the sign-in, so it is never written.
- Measured only (Disk screen): Windsurf (encrypted cascade `.pb`), Trae (encrypted database), Warp (live synced
  app database), Amp (threads live on the server; nothing destructive offered), Junie (layout undocumented),
  iFlow (service shut down; footprint only).

## Herdr (terminal workspace manager agents run in)

Verified on the development Mac, 2026-11-27: `/opt/homebrew/bin/herdr` 0.9.5 (Homebrew, the only Cellar version), headless `herdr server` (ppid 1), the Herdr app `~/Applications/Herdr.app` (`dev.herdr.app` 0.1.7, 61 MB). Only read-only commands were run (`--help`, `status`, `workspace|tab|pane|agent list`, `pane process-info`, `pane layout`, `api snapshot`, `api schema`, `integration status`). Docs: https://herdr.dev/llms-full.txt and `docs/next/website/src/content/docs/` in herdrdev/herdr v0.9.5.

**Folders** (names and sizes only):
- `~/.config/herdr/` (about 230 KB): `config.toml`, `config.toml.bak` (written by `config reset-keys`), `herdr-server.log` (113 KB), `herdr-client.log`, `herdr.log` when present, `session.json` (layout plus the agents' native session ids used to resume on restore), `session-snapshots/` (at most 48, one per 15 minutes at most), `session-backups/` (3 newest copies of unreadable `session.json`, docs), `session-history.json` only with `[experimental] pane_history`, `.plugins.lock`, and sockets `herdr.sock` (API), `herdr-client.sock`, `herdr.sock.agent` (symlink to the launchd SSH agent). Named sessions keep their own state and logs under `sessions/<name>/` (docs). `HERDR_CONFIG_PATH` moves the config, `HERDR_SOCKET_PATH` the socket.
- `~/.config/herdr-app/` (about 16 MB, the app): `mods/` (14 MB), `icons/`, `layouts/`, `themes/`, `telemetry/`, `data/`, `frame/`, `installed.json`, `settings.json`, `view.json`, `window.json`, `herdr-app.sock`. Also `~/.local/bin/herdr-core` (5 MB), `herdr-app` and `hc` symlinks, `~/Library/Preferences/dev.herdr.app.plist`.
- Nothing in `~/Library/Application Support`, `~/Library/Caches` or `~/Library/Logs`.
- Worktrees: `[worktrees] directory` in `config.toml`, default `~/.herdr/worktrees`, laid out `<directory>/<repo>/<branch-slug>` (`herdr --default-config`). `herdr worktree remove` runs `git worktree remove` and keeps the branch. None exist yet on the development Mac.
- Old binaries: the docs do not mention `.old` files for `herdr update` on macOS. `~/.local/bin/agy.<n>.old` (157 MB) is Antigravity's self-update leftover, not Herdr's.

**Processes**: `herdr server` is a launchd child; every pane is a login shell (`-zsh`) whose parent is the server, and agents run below those shells. `herdr pane process-info --pane <id>` gives `.result.process_info.shell_pid` (and foreground command lines, which Domovy never decodes). Domovy maps an agent tree to its pane by walking up to a shell pid, and never counts anything below a Herdr process as orphaned.

**JSON (protocol 22)**: every command prints `{"id": ..., "result": {...}}`; server errors are JSON on stderr with exit 1, syntax errors exit 2. `workspace list` → `workspaces[]` with `workspace_id` (`w1`), `label`, `number`, `active_tab_id`, `pane_count`, `tab_count`, `agent_status`, `focused`. `pane list` → `panes[]` with `pane_id` (`w1:p1`), `tab_id`, `workspace_id`, `cwd`, `foreground_cwd`, `agent_status`, `terminal_id`, `terminal_title` (may echo agent content: never read). `agent list` → `agents[]` with the pane fields plus `agent` (kind), `name`, `completion_seq`, `state_change_seq` and `agent_session` `{agent, kind: "id"|"path", source, value}` when the agent's Herdr integration reported its session: Claude Code and Codex session ids match Domovy's session ids exactly. `api snapshot` has the same lists but no `agent_session`. `workspace create` / `tab create` → `.result.root_pane.pane_id`; `agent start` → `agent_started` with `agent` and `argv`. Statuses: `idle`, `working`, `blocked`, `done`, `unknown`.

**Integrations** (`herdr integration install <agent>`) write a hook script into the agent's own config and register it there: `~/.claude/hooks/herdr-agent-state.sh` + `settings.json` hooks, `~/.codex/herdr-agent-state.sh` + `hooks.json` + `[features] hooks = true`, `~/.config/opencode/plugins/herdr-*.js`, `~/.cursor/herdr-agent-state.sh` + `hooks.json`, `~/.gemini/config/hooks/herdr-agent-state.sh` (Antigravity CLI), and similar for the others. These are agent configuration: keep them. Installed here: claude v11, codex v10, opencode v13, cursor v2, antigravity-cli v4.

**MCP and skills**: Herdr has no MCP server or skills config of its own (no mention in the docs or `--default-config`); it ships one skill (`herdr --skill`) for agents. Panes inherit the user's environment plus `HERDR_ENV=1`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_WORKSPACE_ID`, `HERDR_SOCKET_PATH`, `HERDR_BIN_PATH`, `TERM_PROGRAM=herdr`, so agents started by Herdr read their normal `~/.claude`, `~/.codex` config and get Domovy's MCP server and skill from `domo connect` already. Herdr is not a connect target.

**Domovy's use**: Processes grouped by workspace and pane; live sessions say "Live in Herdr: <workspace>, pane <id>" and are refused; Resume opens a new tab in the workspace whose pane works in the project folder (else a new workspace there) and runs `herdr agent start <name> --kind <kind> --pane <id> -- <resume args>`; Show in Herdr runs `herdr agent focus <pane>`. Disk: logs safe, layout snapshots consequences, layout/settings and the app keep; Herdr worktrees appear among leftovers (a pane shell working inside one keeps it).

### Herdr agent kinds Domovy does not support yet

Herdr kinds: pi, claude, codex, gemini, cursor, devin, agy, cline, omp, mastracode, opencode, copilot, kimi, kiro, droid, amp, grok, hermes, kilo, qodercli, qwen, letta, maki, muse. Domovy lists sessions for claude, codex, gemini, cursor, agy, cline, opencode, copilot, kimi, kiro, droid, grok, kilo, qwen and measures amp. None of the folders below exist on the development Mac; all from docs ([D]) or third-party readers ([3P]).

| Kind (binary) | Sessions | Source |
|---|---|---|
| pi (`pi`) | `~/.pi/agent/sessions/--<cwd-dashed>--/<timestamp>_<id>.jsonl` (JSONL tree); `PI_CODING_AGENT_DIR` overrides | [D] https://pi.dev/docs/latest/session-format |
| omp (`omp`, oh-my-pi) | `~/.omp/agent/sessions`, likely pi's format (fork) | [3P] https://cmux.com/docs/agent-integrations/oh-my-pi |
| devin (`devin`) | SQLite `sessions.db` under `~/.local/share/devin/`; config `~/.config/devin/config.json`; `DEVIN_SESSIONS_DIR` overrides | [D] https://docs.devin.ai/federal/air-gapped/on-disk-formats |
| hermes (`hermes`) | `~/.hermes/state.db` (SQLite, WAL, FTS5), older `~/.hermes/sessions/*.jsonl`; `HERMES_HOME` overrides | [D] https://hermes-agent.nousresearch.com/docs/developer-guide/session-storage |
| qodercli (`qodercli`) | `~/.qoder/projects/<project>/<session-id>.jsonl` + `<session-id>/state.json`; `QODER_CONFIG_DIR` overrides | [D] https://docs.qoder.com/cli/sessions |
| letta (`letta`) | on Letta's server by default; local mode `~/.letta/lc-local-backend` | [D] https://docs.letta.com/letta-code/local-mode |
| mastracode (`mastracode`) | `~/Library/Application Support/mastracode/mastra.db` (LibSQL); `~/.mastracode/` is config | [D] https://mastra.ai/docs/mastra-code/configuration |
| maki (`maki`) | undocumented; `maki session export/import` exists; config `~/.config/maki/init.lua` | [D] https://github.com/tontinton/maki |
| muse (`muse`) | not identified | ? |
