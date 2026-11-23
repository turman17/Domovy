# Domovy: plan

Domovy (домовий, the Ukrainian house spirit who keeps the home in order) is a native macOS app that cleans up after AI coding agents: find every agent session on the Mac, archive the ones worth keeping, delete the rest properly, and get the disk (and later the RAM) back.

Native Swift. Offline. Open source (GPL-3.0). Same family as FinderConvert, MarkPeek and FineTune.

Research behind this plan: [docs/research/](docs/research/).

## 1. Problem

AI agents write a lot to disk and never clean it up, and they give users no proper way to manage what they wrote.

**Disk fills up.**
- **This Mac (2026-11-22):** about 20 GB of agent data, excluding models.
  - Claude Desktop `vm_bundles`: 10 GB
  - `~/.claude`: 3.0 GB
  - `~/.codex`: 2.9 GB
  - `~/.cursor`: 1.8 GB
  - Ollama models add another 17 GB.
- **Claude Desktop VM:** the 10 GB Cowork VM bundle has 240 upvotes and 86 comments, still open (anthropics/claude-code#22543). Unbounded growth of that VM is #65577.
- **Codex:** users report `~/.codex/sessions` using 100+ GB. Single stores of 34 GB and 755 GiB are reported. Rollouts bloat from compaction snapshots and inline images.
- **Cursor:** `state.vscdb` reaches 30–97 GB. One Reddit user writes "Cursor took over my 250GB".

**A session cannot be deleted properly.**
- Claude Code has no per-session delete (#26904: 115 upvotes, open).
- Deleting a session in Claude Desktop removes only its registry JSON. The plaintext transcript stays on disk (#89547).
- One Claude Code session is spread over 5–10 places, so nobody can delete it by hand reliably.
- Transcripts contain pasted secrets, keys and personal data.

**History disappears silently.**
- Claude Code deletes transcripts after 30 days by default, keyed on file modification time, with no warning: #99817 (open), #90667, #64999, #62250, #105500.
- Antigravity keeps only 500 conversations, and Gemini CLI also deletes after 30 days.

**Processes are left behind** (secondary). Orphaned agent processes and MCP servers, and leaks up to 113 GB.

## 2. Goal and audience

- **Goal:** GitHub stars and reputation first. Money is optional later (donations, or a paid Pro tier if one ever makes sense).
- **Users:** developers on macOS who use two or more of Claude Code, Codex, Cursor, Gemini or Antigravity, OpenCode, Copilot CLI and local models.
- **Signals that this category gets attention:**
  - tw93/Mole, a general Mac cleaner, has 75.8k stars.
  - morajabi/poo, a cleaner for developer disk space, got 104 stars in its first week (November 2026).

## 3. Competition and gap

| Tool | Stars | Does | Missing |
|---|---|---|---|
| Mole | 75.8k | General Mac cleaner | Does not understand agent sessions; Claude VM cleanup only requested (#537) |
| poo | 104 | Builds, caches, worktrees (Rust, menu bar + CLI + MCP) | Sessions |
| claude-code-cleaner | 54 | Rust TUI, Claude only, by category | Other agents, GUI, per-session view. Wrongly treats `plugins/` as cleanable |
| leftovers | 11 | Swift menu bar: processes, memory, dev caches | Sessions |
| compress-agent-sessions | 2 | APFS compression of cold session files | Everything else |
| Sealkeep | paid | Backup and search of agent history | Cleanup, deletion |
| RAM tools (ctop, agent-manager-x, seshka, membrake, ...) | 0–95 | Process monitor, orphans | Disk and sessions |

**The gap:** none of these deletes a single session together with its Desktop, Codex or Cursor index entries. None works across all agents in one native app, and none warns before a retention sweep deletes history.

## 4. Product

### Principles (non-negotiable)

1. **Never lose data the user did not choose to lose.** Every destructive action:
   - shows a preview of exactly which files and index rows will change;
   - goes to the Trash or to a quarantine folder first;
   - is logged and can be undone until the user empties it.
2. **Never touch a live session.** Check for open file handles (libproc), Claude `~/.claude/sessions/*.json` and `daemon/roster.json`, Codex lock files and Antigravity `presence/*.lock`.
3. **Use official commands where they exist**, such as `codex delete`, `codex archive`, `opencode session delete`, `ollama rm` and `hf cache rm`. Edit files directly only where no official command exists.
4. **Preserve file modification times.** Retention in Claude Code and Gemini is keyed on mtime.
5. **Offline.** No network, no telemetry. The app reads transcripts only to show and search them locally.
6. **Never delete what an agent needs to run.** That includes `plugins/`, `settings.json`, `projects/<slug>/memory/`, `auth.json` and `config.toml`.

### Features

**A. Sessions** (core, the reason to install)
- One list of all sessions across agents: title or first prompt, project, agent, date, size, and whether it is live.
- Search across sessions and preview a transcript with a native renderer. MarkPeek-style rendering can be reused here.
- **Delete properly:** remove every artifact of the session plus its index entries (see section 5).
- **Archive:** compress cold sessions with APFS transparent compression so agents can still resume them, or export to a dated archive folder or zip.
- **Protect from retention:** warn "these N sessions will be deleted by Claude Code in X days" and offer to archive them first. Show and edit `cleanupPeriodDays` with a clear explanation.
- **Secret scan:** find API keys and tokens in transcripts (gitleaks-style rules), then redact them or delete the session.
- **Orphan finder:** companion folders whose transcript is gone, Desktop registry entries whose transcript is gone, and duplicate transcripts left after a Desktop restart (#89592).

**B. Disk**
- Per-agent breakdown with sizes. Each entry is marked: safe to remove, removable with consequences (with the consequences explained), or keep.
- Guided cleanups:
  - Claude Desktop VM bundle (warn that Cowork state is lost and the VM may be downloaded again)
  - Codex huge rollouts (archive or compress)
  - Cursor `state.vscdb` (guide the user to run Cursor's own GC, then quit; never run a raw `VACUUM` on chats)
  - merged agent worktrees
  - Ollama and LM Studio models unused for N days, plus orphaned Ollama blobs
  - Hugging Face cache, via `hf cache prune`

**C. Processes** (later; covered by other tools, so it ships as a module)
- Per-session RAM and CPU including child processes and MCP servers.
- Orphaned processes, leak detection by growth rate, and freeze (SIGSTOP) instead of kill.

**D. Surfaces**
- A menu bar item showing total agent disk use and a warning count (sessions expiring soon, live leaks).
- A main window with three tabs: Sessions, Disk, Processes.
- A `domo` CLI with the same core engine, for scripts and power users: `domo ls`, `domo rm <id>`, `domo archive --older 30d`, `domo du`. Later, possibly an MCP server or skill so agents can run cleanup themselves.

## 5. Storage map (adapters)

Each agent is one adapter. It implements: list sessions, list a session's artifacts, check whether a session is live, delete, archive, and report disk use.

**Claude Code CLI** (`~/.claude`)
- Transcript: `projects/<slug>/<uuid>.jsonl`. The slug is the project path with `/` replaced by `-`.
- Companions keyed by the same uuid:
  - `projects/<slug>/<uuid>/` (`subagents/*.jsonl`, `*.meta.json`, `tool-results/`, `mcp-tasks/`)
  - `.orphaned-*` and `.superseded-*` copies of the transcript
  - `file-history/<uuid>/`, `uploads/<uuid>/`, `dev-mods/<uuid>/`, `session-env/<uuid>`
  - `security/security_warnings_state_<uuid>.*`
  - scratchpad under `/private/tmp/claude-<uid>/<slug>/<uuid>/`
  - matching lines in `history.jsonl`
- Never touch: `projects/<slug>/memory/`, `plugins/`, `settings.json`, `skills/`, `keybindings.json`, `CLAUDE.md`.
- Live: `sessions/<pid>.json`, `daemon/roster.json`, open handles.
- Official commands: `claude purge` (per project or `--all`); there is no per-session delete yet.
- Retention: `cleanupPeriodDays`, default 30, keyed on mtime.
- Local bloat seen: `security/agent-sdk-venv` 360 MB; the largest transcripts are 30–86 MB.

**Claude Desktop** (`~/Library/Application Support/Claude`)
- Registry: `claude-code-sessions/<uuid>/<uuid>/local_<uuid>.json` (`cliSessionId`, `isArchived`, `title`, `priorCliSessionIds`; verified). The app overwrites edits to these files unless it is fully quit, so require Desktop to be quit before editing them.
- Cowork data: `local-agent-mode-sessions/` (`audit.jsonl`, `scheduled-tasks.json`).
- VM: `vm_bundles/claudevm.bundle` (`rootfs.img` 10 GiB, `rootfs.img.zst`, `sessiondata.img`).
- Electron caches: `Cache/`, `Code Cache/`, `GraphiteDawnCache/`.
- Retention: `desktopSessionCleanupPeriodDays` (v2.1.248+).

**Codex** (`~/.codex`)
- Rollout: `sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl`, or `.jsonl.zst` when compression is on. Archived rollouts are in `archived_sessions/`.
- Index entries:
  - `session_index.jsonl`
  - `state_5.sqlite` (`threads`, `thread_spawn_edges`, `thread_attachments`)
  - `thread_history_1.sqlite` (235 MB here)
  - `logs_2.sqlite` (68 MB here)
  - `sqlite/codex.db` (`local_thread_catalog*`)
- Also: `attachments/`, `generated_images/`, `worktrees/<id>/<repo>`.
- Official commands: `codex archive`, `codex unarchive`, `codex delete [--force <uuid>]`. Prefer these. They have known bugs with archived sessions (#58366, #36558), so verify the result after running them.
- Never touch: `auth.json`, `config.toml`, `rules/`, `skills/`, `plugins/`.

**Cursor**
- Chats are rows in `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (`composerData:`, `bubbleId:`, `checkpointId:`, `messageRequestContext:`, `agentKv:`). The chat list is `composer.composerHeaders` (Cursor 3.0+).
- CLI chats: `~/.cursor/chats/<hash>/<uuid>/`.
- Verified on a real (pre-3.0) install, read-only and in place (2026-11-23): tables `ItemTable` and `cursorDiskKV` (`key TEXT UNIQUE, value BLOB`, JSON text values); per-chat keys `composerData:<id>` and `<prefix>:<id>:<item>` for `bubbleId`, `checkpointId`, `messageRequestContext`, `codeBlockDiff`, `codeBlockPartialInlineDiffFates`; helper processes `Cursor Helper (…)`. `composer.composerHeaders`, `agentKv:` and CLI chats were not on that install (assumed).
- Delete (v0.5) is the first SQLite write in Domovy: only with Cursor fully quit and nothing holding `state.vscdb`, `-wal` or `-shm` open; clone the database into the quarantine; `BEGIN IMMEDIATE`, delete exactly the chat's rows and cut its entry out of `composer.composerHeaders` byte for byte, `COMMIT`; `PRAGMA integrity_check` or the clone goes back. Never VACUUM; Cursor reclaims the space itself or with "Developer: GC Agent KV Blobs". Undo puts the clone back only while the file is unchanged since (the user accepts that explicitly). A chat also listed in a pre-3.0 workspace database is refused. CLI chats move to the Trash and archive with APFS compression; editor chats have no archive.

**Later adapters**
- Gemini CLI: `~/.gemini/tmp/<project>/{chats,logs,tool-outputs,checkpoints}`, `~/.gemini/history/<project>` (`<project>` from `projects.json`; older versions used a hash). Official `--delete-session` also deletes chats sharing the id's first 8 characters and runs the retention sweep first, which deletes other chats for good (verified 0.43.0), so Domovy never runs it and moves the files itself. Empty chats sharing one id (the a2a server's, 427 here) are one row.
- Antigravity: `~/.gemini/antigravity-cli/{brain,conversations/*.db}` for the `agy` CLI (verified 1.5.8), `~/.gemini/antigravity/{brain,conversations/*.db,annotations,presence}` for the app. Retention keeps 500 conversations. No delete command, so Domovy is read-only for it.
- OpenCode: `~/.local/share/opencode/opencode.db` (`session`, `message`, `part`, `event`, plus sign-ins; verified 1.18.30). Delete runs the official `opencode session delete` with OpenCode quit, after cloning the database (undo only while nothing else wrote to it, which the user accepts explicitly), and checks the rows are gone. Domovy never writes the database. The `event` table bloats and has no compaction command. No archive: no file belongs to one session.
- Copilot CLI: `~/.copilot/session-state/<id>/events.jsonl` and `session-store.db` (assumed, not installed here). Delete moves the session folder; Domovy never runs `/chronicle reindex`, which syncs to the user's account, and only reports index rows that stay.
- Models: Ollama (`ollama rm`, content-addressed blobs), LM Studio `~/.lmstudio/models`, Hugging Face (`hf cache rm` and `hf cache prune`).

## 6. Architecture

```
Domovy.app        SwiftUI main window + MenuBarExtra
domo (CLI)             swift-argument-parser, same core
DomovyCore        Swift package, no UI
  Adapters/           ClaudeCode, ClaudeDesktop, Codex, Cursor, ...
  Model/              Session, Artifact, IndexEntry, Footprint
  Scan/               scanner with a cache; FSEvents for updates
  Safety/             LiveSessionDetector (libproc), Plan (dry run), Quarantine, UndoLog
  Actions/            Delete, Archive (APFS compression), Export, Redact
  Secrets/            rule-based secret scanner
  Processes/          (v0.4) process tree, footprint, freeze
```

- **Every action is a two-step `Plan`:** first compute the exact file and DB changes and show them, then execute. The same plan object drives the UI preview and the CLI `--dry-run`.
- **SQLite:** use the system `libsqlite3`, read-only for scans. Write only through an adapter that checks the owning app is not running, and back up the DB first.
- **zstd:** needed to read Codex `.jsonl.zst` files. Use a small vendored libzstd, the way FinderConvert vendors LAME and libwebp.
- **Distribution:** not sandboxed (it must read `~/.claude` and the other agent folders), macOS 14+, GitHub Releases and Homebrew tap, self-update as in FinderConvert.
- **Signing:** strongly consider a paid Apple Developer account and notarization for this app. It deletes files, so trust matters. Homebrew disabled 598 unnotarized casks on 2026-09-01.

## 7. Milestones

**v0.1, weeks 1–3: Sessions for Claude Code and Codex**
- Core package and the two adapters, with a fixture-based test suite built from a fake home directory with synthetic sessions. Never test against the real `~`.
- Session list, search, transcript preview, size and live status.
- Proper delete (to quarantine), undo, archive with APFS compression.
- Disk tab, read-only, for Claude, Claude Desktop, Codex and Cursor.
- CLI: `domo ls`, `domo du`, `domo rm --dry-run`.

**v0.2, weeks 4–5: Safety and history**
- Retention warning and "archive before Claude deletes it".
- Secret scan and redaction.
- Orphan finder, including Desktop registry orphans and duplicates.
- Claude Desktop registry cleanup (Desktop must be quit).

**v0.3, weeks 6–7: Disk cleanups**
- Guided VM bundle cleanup, Codex rollout compression, worktree cleanup, model cleanup (Ollama, LM Studio, Hugging Face).
- Menu bar warnings.

**v0.4: Processes module**
- Per-session RAM and CPU, orphaned processes, freeze.

**v0.5: More agents**
- Gemini and Antigravity, OpenCode, Copilot CLI.
- Cursor write support.

## 8. Launch

- **Headline built on real numbers:** "I found 20 GB of AI agent leftovers on my Mac. This app finds yours, and deletes a Claude Code session properly, which Claude itself cannot do."
- **Assets:** a 30-second GIF (scan, list, delete one session, undo), a before-and-after disk screenshot, and a landing page in the same style as the MarkPeek and FinderConvert sites.
- **Channels:**
  - Show HN
  - r/ClaudeCode, r/codex, r/cursor, r/macapps
  - comments on #26904, #22543, #89547 and #99817, only where they help directly, without spamming
  - a PR or issue on Mole pointing to the session engine
- **Make it easy to try:** `brew install --cask turman17/tap/domovy`, and the CLI via `brew install`.

## 9. Success and kill criteria

- **30 days after v0.1 launch:**
  - Target: at least 300 stars and at least 10 issues from strangers.
  - Below 100 stars and no outside issues: stop adding features and fold the useful parts into FinderConvert or MarkPeek, or contribute them to Mole.
- **90 days:**
  - Target: at least 1,000 stars, with at least 3 adapters contributed or maintained by others.
- **Native-fix check:** if Anthropic ships per-session delete and Desktop transcript cleanup, the cross-agent, disk and archive features must still justify the app. Re-check at every major Claude Code release.

## 10. Risks

| Risk | Mitigation |
|---|---|
| Deleting user data by mistake | Dry-run plans, quarantine, undo log, never touching live sessions, a test suite on fixture homes |
| Storage formats change with agent updates | Adapters behind a versioned protocol; detect unknown layouts and fall back to read-only |
| Vendors add native delete or retention controls | Cross-agent view, disk and archive features remain; be first and best |
| Editing app databases corrupts them | Prefer official CLIs, require the owning app to be quit and nothing holding the file open, clone it first, one transaction, integrity check with automatic restore, never VACUUM (Cursor) |
| Secrets left in the Trash | Offer "delete now" for sessions flagged by the secret scan, and say clearly that the Trash still holds plaintext |
| Unsigned app looks unsafe | Notarize; publish the source and reproducible builds |

## 11. Verify before coding

- [ ] Claude Desktop: does the VM bundle download again after deletion, and what exactly is lost? No official Anthropic statement was found.
- [x] Claude Desktop registry JSON format, taken from a real install (verified 2026-11-23; see docs/research/agent_storage_formats.md).
- [ ] Codex: do `codex delete` and `codex archive` clean `state_5.sqlite` and `session_index.jsonl` in the current version? Test on a throwaway session.
- [ ] libproc API for open file handles per path, without root.
- [ ] Does APFS compression of a `.jsonl` file survive Claude Code appending to it? It decompresses on write, which is fine for cold sessions only.
- [ ] Codex screenshot duplicates and Cursor `.pack` files: no sources yet.
- [x] Cursor `state.vscdb` schema, per-chat key shapes and helper process names, read-only in place (verified 2026-11-23 on a pre-3.0 install; see docs/research/agent_storage_formats.md).
- [ ] Cursor 3.0+: `composer.composerHeaders` shape, `agentKv:` key shapes, the main process name, and whether a chat deleted this way stays deleted after Cursor restarts. Check on a current install with a throwaway chat.
- [ ] Cursor CLI: `~/.cursor/chats/<hash>/<id>/store.db` `meta` format and the `cursor-agent` process name. Not installed here.
- [x] Ollama store and Hugging Face hub cache layouts, taken from a real install (verified 2026-11-23; see docs/research/agent_storage_formats.md).
- [ ] LM Studio model layout and process names; `hf cache rm` / `hf cache prune` argument forms; the Ollama server's process name and `ollama ps` output while a model is loaded.
- [x] Gemini CLI layout, chat format, `--delete-session` semantics and retention defaults, taken from a real install and its source (verified 2026-11-23; see docs/research/agent_storage_formats.md).
- [x] Antigravity CLI (`agy`) store layout and SQLite schemas (verified 2026-11-23).
- [ ] Antigravity desktop app: `~/.gemini/antigravity` layout, `presence/*.lock`, process names, and whether it has a safe delete. Not installed here.
- [ ] Antigravity conversation format (`brain/<id>/.system_generated/logs/transcript.jsonl`, the `.db` step payloads), for a transcript preview.
- [ ] Gemini CLI: do project `.gemini/settings.json` files override `sessionRetention`? (`--delete-session` is no longer used.)
- [x] OpenCode data folder, SQLite schema and CLI (`session delete`, no compaction command), taken from a real install (verified 2026-11-23; see docs/research/agent_storage_formats.md).
- [ ] OpenCode: does `opencode session delete` remove the session's `event` rows, and does it honour `XDG_DATA_HOME`? Test on a throwaway session.
- [ ] Copilot CLI: `~/.copilot` layout, `events.jsonl` shape, `session-store.db` schema, lock files and process names. Not installed here.
- [x] Name: Domovy (домовий, the Ukrainian house spirit who keeps the home in order). CLI: `domo`.
