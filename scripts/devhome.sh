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
SUPPORT="$DEV/Library/Application Support"
if [ ! -d "$SUPPORT/Claude" ]; then
  mkdir -p "$SUPPORT"
  cp -Rp "$ROOT/Tests/Fixtures/claude-desktop/1.0" "$SUPPORT/Claude"
  # A sparse stand-in for the 10 GiB Cowork VM image: large logically, a few KB on disk.
  dd if=/dev/zero of="$SUPPORT/Claude/vm_bundles/claudevm.bundle/rootfs.img" bs=1 count=0 seek=10g 2>/dev/null
  dd if=/dev/urandom of="$SUPPORT/Claude/vm_bundles/claudevm.bundle/rootfs.img" bs=1m count=24 conv=notrunc 2>/dev/null
  dd if=/dev/urandom of="$SUPPORT/Claude/Cache/Cache_Data/data_1" bs=1m count=6 2>/dev/null
fi
if [ ! -d "$SUPPORT/Cursor" ]; then
  mkdir -p "$SUPPORT"
  cp -Rp "$ROOT/Tests/Fixtures/cursor/3.0/support" "$SUPPORT/Cursor"
  cp -Rp "$ROOT/Tests/Fixtures/cursor/3.0/dot-cursor" "$DEV/.cursor"
  dd if=/dev/urandom of="$SUPPORT/Cursor/User/globalStorage/state.vscdb" bs=1m count=9 2>/dev/null
  dd if=/dev/urandom of="$DEV/.cursor/extensions/example.theme-1.0.0/theme.bin" bs=1m count=3 2>/dev/null
fi
if [ ! -d "$DEV/.claude/security/agent-sdk-venv" ]; then
  # Disk screen extras: a rebuildable venv and a companion whose transcript is gone.
  mkdir -p "$DEV/.claude/security/agent-sdk-venv/lib"
  dd if=/dev/urandom of="$DEV/.claude/security/agent-sdk-venv/lib/site.bin" bs=1m count=4 2>/dev/null
  ORPHAN="$DEV/.claude/file-history/eeeeeeee-5555-4555-8555-555555555555"
  mkdir -p "$ORPHAN"
  dd if=/dev/urandom of="$ORPHAN/snapshot.bin" bs=1k count=640 2>/dev/null
  touch -t "$(date -v-5d +%Y%m%d%H%M)" "$ORPHAN"
fi
if [ ! -f "$DEV/.secrets-seeded" ]; then
  # Synthetic, obviously fake secrets for the secret scan. Each value is split in two here so
  # no token-shaped literal sits in the repository.
  ANT="sk-""ant-api03-FAKEfake0123456789FAKEfake0123456789a1B2"
  AWS="AKIA""EXAMPLEFAKE00001"
  GH="ghp""_FAKEfakeFAKEfakeFAKEfakeFAKEfake0000"
  OAI="sk-""proj-FAKEa1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuV"
  P="$DEV/.claude/projects"
  A="$P/-Users-dev-code-orbit-api/aaaaaaaa-1111-4111-8111-111111111111.jsonl"
  C="$P/-Users-dev-code-landing-site/cccccccc-3333-4333-8333-333333333333.jsonl"
  X="$DEV/.codex/sessions/2026/11/20/rollout-2026-11-20T09-15-00-01a1f011-1111-7111-8111-111111111111.jsonl"
  printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"Use ANTHROPIC_API_KEY=$ANT for the eval run\"},\"cwd\":\"/Users/dev/code/orbit-api\",\"sessionId\":\"aaaaaaaa-1111-4111-8111-111111111111\",\"timestamp\":\"2026-11-20T10:05:00.000Z\"}" >> "$A"
  printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"The staging db password=Zq8vN3xLm2Pw7Rt, AWS key $AWS\"},\"cwd\":\"/Users/dev/code/orbit-api\",\"sessionId\":\"aaaaaaaa-1111-4111-8111-111111111111\",\"timestamp\":\"2026-11-20T10:06:00.000Z\"}" >> "$A"
  printf '%s\n' "deploy log: using token $GH" >> "$DEV/.claude/projects/-Users-dev-code-orbit-api/aaaaaaaa-1111-4111-8111-111111111111/tool-results/r1a2b3c4d.txt"
  printf '%s\n' "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"export GH_TOKEN=$GH and push\"},\"cwd\":\"/Users/dev/code/landing-site\",\"sessionId\":\"cccccccc-3333-4333-8333-333333333333\",\"timestamp\":\"2026-10-28T10:00:00.000Z\"}" >> "$C"
  printf '%s\n' "{\"timestamp\":\"2026-11-20T09:16:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"Run the evals with $OAI\",\"images\":[]}}" >> "$X"
  age() { touch -t "$(date -v-"$1"d +%Y%m%d%H%M)" "$2"; }
  age 2 "$A"; age 26 "$C"; age 2 "$X"
  touch "$DEV/.secrets-seeded"
fi
if [ ! -f "$DEV/.desktop-seeded" ]; then
  # Claude Desktop registry with the verified layout: a linked session, an entry whose
  # transcript is gone, a doubled entry, and a conversation Desktop continued under a new id.
  REG="$SUPPORT/Claude/claude-code-sessions"
  rm -rf "$REG"
  cp -Rp "$ROOT/Tests/Fixtures/claude-desktop/1.0/claude-code-sessions" "$REG"
  E="$REG/3f6e1a2b-0c4d-4e5f-8a9b-1c2d3e4f5a6b/9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
  PRIOR="99999999-9999-4999-8999-999999999999"
  sed "s/\"priorCliSessionIds\": \[\]/\"priorCliSessionIds\": [\"$PRIOR\"]/" "$E/local_5e1d2f3a-0000-4000-8000-000000000001.json" > "$E/tmp.json"
  mv "$E/tmp.json" "$E/local_5e1d2f3a-0000-4000-8000-000000000001.json"
  P="$DEV/.claude/projects/-Users-dev-code-orbit-api"
  head -n 4 "$P/aaaaaaaa-1111-4111-8111-111111111111.jsonl" | sed "s/aaaaaaaa-1111-4111-8111-111111111111/$PRIOR/g" > "$P/$PRIOR.jsonl"
  age() { touch -t "$(date -v-"$1"d +%Y%m%d%H%M)" "$2"; }
  for f in "$E"/local_*.json; do age 2 "$f"; done
  age 1 "$E/local_5e1d2f3a-0000-4000-8000-000000000003.json"
  age 6 "$P/$PRIOR.jsonl"
  age 9 "$P/aaaaaaaa-1111-4111-8111-111111111111.orphaned-20261101-x7q2k.jsonl"
  age 9 "$P/aaaaaaaa-1111-4111-8111-111111111111.jsonl.superseded-20261101-120000"
  # A prompt with a synthetic key in history.jsonl, for the history scan.
  OAI="sk-""proj-FAKEa1B2c3D4e5F6g7H8i9J0kLmNoPqRsTuV"
  H="$DEV/.claude/history.jsonl"
  printf '%s\n' "{\"display\":\"Run the evals with $OAI\",\"pastedContents\":{},\"timestamp\":1763629300000,\"project\":\"/Users/dev/code/orbit-api\",\"sessionId\":\"aaaaaaaa-1111-4111-8111-111111111111\"}" >> "$H"
  touch "$DEV/.desktop-seeded"
fi
