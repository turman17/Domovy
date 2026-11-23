# Agent housekeeping on macOS: sessions, disk, RAM (2026-11-22)

## User's own Mac (du, read-only)
~/.claude 3.0G (projects 2.5G, 407 jsonl); ~/.codex 2.9G (sessions 989M); ~/.cursor 1.8G;
~/Library/Application Support/Claude 11G (vm_bundles 10G); ~/.gemini 396M; ~/.opencode 199M;
~/.ollama/models 17G; ~/.cache/huggingface 1.4G. Agents ~20G, with models ~38G.

## Disk bloat evidence
- claude-code #22543 Cowork 10GB VM bundle degrades perf: open, 240 thumbs, 86 comments
- #65577 VM rootfs grows unbounded: open, 23 thumbs; #75302, #61863 same
- Mole issue tw93/Mole#537 "Clean Claude VM Bundle" (Mole = 75.8k stars Mac cleaner)
- Codex: r/codex 1vzu2wi ".codex/sessions using 100+GB"; 1w8b699 "71% of ~/.codex was screenshots (22 GB)"; openai/codex#20864 app lags scanning sessions
- Cursor: r/cursor 1s5lf5u "took over my 250GB"; forum: state.vscdb 30GB, 125GB, +1GB/day
- claude-code #20429 no retention -> startup degraded/OOM; #24486 GC request

## Deletion / privacy evidence
- #26904 "/delete command to delete current session": open, 115 thumbs, 26 comments
- #89547 Desktop delete removes registry only, plaintext transcript stays on disk
- #67201 per-session server-side delete; #24126 GDPR delete; #30078 delete individual conversations

## Opposite pain: silent loss of history
- cleanupPeriodDays=30 deletes transcripts: #99817 (open), #90667, #64999, #62250, #109897, #105500; r/ClaudeCode 1xaejai PSA

## Existing tools
- Mole 75.8k (general cleaner; Claude VM only requested), poo 104 stars in 7 days (Rust, dev disk + worktrees, menu bar+CLI+MCP)
- claude-code-cleaner 54 (Rust TUI, Claude only), claude-clean 3, claudeclean 1, agent-cleanup 2, agent-cache-cleaner 0, compress-agent-sessions 2, stale 3
- Sealkeep (sealkeep.spala.ai): backup/seal agent history, guides; commercial
- Session browsers: claude-sessions-manager variants 0-6 stars; opcode 22k (GUI, not cleanup)
- RAM side: see prior notes (ctop 95, agent-manager-x 75, leftovers 11, membrake 3, headroom 0, modelnap 24)

## Gap
Nobody ships one native app across Claude CLI + Desktop, Codex, Cursor, Gemini, OpenCode that:
browse/search sessions, delete a session with ALL artifacts, archive/compress + protect from 30-day purge,
clean VM bundle/state.vscdb/screenshot dupes safely, plus process/orphan module.
