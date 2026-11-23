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

**Gemini CLI and Antigravity**
- Gemini CLI sessions: `~/.gemini/tmp/<project_hash>/chats/`. Manual `/chat` checkpoints and file checkpoints are in `~/.gemini/tmp/<project_hash>/checkpoints`. The shadow git repo for file snapshots is `~/.gemini/history/<project_hash>`. Deleting a session also removes its plans, task trackers, tool outputs and activity logs. — [gemini-cli session-management.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/session-management.md); [checkpointing.md](https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/checkpointing.md)
- One third-party source says files are named `session-<date>-<id>.jsonl` and that `~/.gemini/projects.json` maps folders to ids. Unverified against official docs. — [groundedby.com](https://groundedby.com/agents/gemini-cli)
- Antigravity, per a third-party guide: `~/.gemini/antigravity/` contains
  - `brain/<id>/` (`transcript.jsonl`, `transcript_full.jsonl`, tool output, `implementation_plan.md`, `walkthrough.md`)
  - `conversations/<id>.db` plus `-wal` and `-shm` (legacy `.pb`)
  - `annotations/<id>.pbtxt`
  - `presence/<id>.lock`
  The Antigravity CLI uses `~/.gemini/antigravity-cli/{conversations,brain}`. — [deja-vu guide](https://vshulcz.github.io/deja-vu/guide/delete-antigravity-history.html); [google-antigravity/antigravity-cli#1417](https://github.com/google-antigravity/antigravity-cli/issues/1417); [Google AI forum](https://discuss.ai.google.dev/t/how-to-delete-conversation-antigravity/114671)

**OpenCode**
- All sessions are in one SQLite DB, `~/.local/share/opencode/opencode.db`, with tables `session`, `part` (message content, including inline base64 attachments), `event` (an append-only event log, one stream per session) and `event_sequence`. — [anomalyco/opencode#53760](https://github.com/anomalyco/opencode/issues/53760); [#32716](https://github.com/anomalyco/opencode/issues/32716)
- Extra per-session files: `~/.local/share/opencode/storage/session_diff`, plus `snapshot/` and `log/`. — [bernard-denis/opencode-cleaner](https://github.com/bernard-denis/opencode-cleaner); [agent-cleanup README](https://github.com/luchasarie/agent-cleanup)
- `~/.opencode/bin/opencode` is a CLI install location. — [opencode-cleaner](https://github.com/bernard-denis/opencode-cleaner)

**GitHub Copilot CLI (`~/.copilot`, or `$COPILOT_HOME`)**
- `session-state/<session-id>/` contains `events.jsonl` plus workspace artifacts (plans, checkpoints, tracked files). `session-store.db` is a SQLite index used for search and `/chronicle`. `logs/process-{timestamp}-{pid}.log` holds per-process logs. `command-history-state/` holds command history. — [GitHub Docs: CLI config dir](https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference)

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
