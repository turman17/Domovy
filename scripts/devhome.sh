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
