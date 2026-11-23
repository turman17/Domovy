#!/bin/sh
# Prepares .devhome/, a fake home built from the test fixtures. Debug runs of the app
# point DOMOVY_ROOT here so development never reads or changes the real ~.
# Usage: scripts/devhome.sh [--reset]
set -eu
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEV="$ROOT/.devhome"
if [ "${1:-}" = "--reset" ]; then rm -rf "$DEV"; fi
if [ ! -d "$DEV/.claude" ]; then
  mkdir -p "$DEV"
  cp -Rp "$ROOT/Tests/Fixtures/claude-code/2.1" "$DEV/.claude"
  CLAUDE="$DEV/.claude"
  # The fixtures are tiny and APFS compression skips files of 16 KiB or less. Add synthetic,
  # compressible tool output so Archive has something to do.
  bulk() { mkdir -p "$(dirname "$2")"; seq 1 "$1" | sed 's/.*/{"type":"tool_result","n":&,"content":"synthetic build output, compiled module without warnings"}/' >> "$2"; }
  bulk 30000 "$CLAUDE/projects/-Users-dev-code-orbit-api/aaaaaaaa-1111-4111-8111-111111111111/tool-results/r9build.txt"
  bulk 12000 "$CLAUDE/projects/-Users-dev-code-landing-site/cccccccc-3333-4333-8333-333333333333.jsonl"
  # Pin transcript ages like the tests do, so idle, expiring and live states all show up.
  age() { touch -t "$(date -v-"$1"d +%Y%m%d%H%M)" "$2"; }
  age 2  "$CLAUDE/projects/-Users-dev-code-orbit-api/aaaaaaaa-1111-4111-8111-111111111111.jsonl"
  age 0  "$CLAUDE/projects/-Users-dev-code-orbit-api/bbbbbbbb-2222-4222-8222-222222222222.jsonl"
  age 26 "$CLAUDE/projects/-Users-dev-code-landing-site/cccccccc-3333-4333-8333-333333333333.jsonl"
  age 10 "$CLAUDE/projects/-Users-dev-code-landing-site/dddddddd-4444-4444-8444-444444444444.jsonl"
  # The fixture's pids do not exist here, so the markers would count as stale. Point the
  # interactive marker at launchd (pid 1, always running) to keep one session visibly live.
  sed 's/"pid":4242/"pid":1/' "$CLAUDE/sessions/4242.json" > "$CLAUDE/sessions/1.json"
  rm "$CLAUDE/sessions/4242.json"
fi
if [ ! -d "$DEV/.codex" ]; then
  mkdir -p "$DEV/bin"
  cp -Rp "$ROOT/Tests/Fixtures/codex/0.169" "$DEV/.codex"
  CODEX="$DEV/.codex"
  for db in state_5 thread_history_1; do sqlite3 "$CODEX/$db.sqlite" < "$ROOT/Tests/Fixtures/codex/sql/$db.sql"; done
  # The app and `domo --root .devhome` run this stub, never the real codex CLI.
  cp "$ROOT/Tests/Fixtures/codex/stub-codex.sh" "$DEV/bin/codex"
  chmod 755 "$DEV/bin/codex"
  age() { touch -t "$(date -v-"$1"d +%Y%m%d%H%M)" "$2"; }
  S="$CODEX/sessions/2026"
  age 2  "$S/11/20/rollout-2026-11-20T09-15-00-01a1f011-1111-7111-8111-111111111111.jsonl"
  age 2  "$S/11/20/rollout-2026-11-20T11-40-00-01a1f011-1111-7111-8111-111111111111_01a1f0aa-aaaa-7aaa-8aaa-aaaaaaaaaaaa.jsonl"
  age 1  "$S/11/22/rollout-2026-11-22T08-00-00-01a1f022-2222-7222-8222-222222222222.jsonl"
  age 24 "$S/10/30/rollout-2026-10-30T14-05-00-01a1f033-3333-7333-8333-333333333333.jsonl.zst"
  age 42 "$S/10/12/rollout-2026-10-12T10-00-00-01a1f055-5555-7555-8555-555555555555.jsonl.zst"
  age 8  "$CODEX/archived_sessions/rollout-2026-11-15T22-41-43-01a1f044-4444-7444-8444-444444444444.jsonl"
fi
