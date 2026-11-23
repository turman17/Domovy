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
if [ ! -f "$DEV/.cleanups-seeded" ]; then
  # Disk cleanups: a large rollout (sparse past its first lines), a logs database, and a clean
  # and a dirty git worktree under .codex/worktrees, from a throwaway repo in .devhome/code.
  CODEX="$DEV/.codex"
  BIG="$CODEX/sessions/2026/11/21/rollout-2026-11-21T10-00-00-01a1f066-6666-7666-8666-666666666666.jsonl"
  mkdir -p "$(dirname "$BIG")"
  printf '%s\n' '{"timestamp":"2026-11-21T10:00:00.000Z","type":"session_meta","payload":{"id":"01a1f066-6666-7666-8666-666666666666","cwd":"/Users/dev/code/orbit-api","cli_version":"0.169.0"}}' > "$BIG"
  seq 1 200000 | sed 's/.*/{"timestamp":"2026-11-21T10:01:00.000Z","type":"compacted","payload":{"n":&,"message":"synthetic compaction snapshot of an earlier turn"}}/' >> "$BIG"
  dd if=/dev/null of="$BIG" bs=1 count=0 seek=150m 2>/dev/null
  touch -t "$(date -v-3d +%Y%m%d%H%M)" "$BIG"
  sqlite3 "$CODEX/logs_2.sqlite" "CREATE TABLE logs(id INTEGER PRIMARY KEY, body BLOB); INSERT INTO logs(body) VALUES (randomblob(2000000));"
  dd if=/dev/urandom of="$CODEX/logs_2.sqlite-wal" bs=1k count=512 2>/dev/null
  G() { GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c user.name=Dev -c user.email=dev@example.invalid -c commit.gpgsign=false "$@" >/dev/null 2>&1; }
  REPO="$DEV/code/orbit-api"
  mkdir -p "$REPO"
  G -C "$REPO" init -b main
  printf '# orbit-api\n' > "$REPO/README.md"
  G -C "$REPO" add README.md
  G -C "$REPO" commit -m "Initial commit"
  mkdir -p "$CODEX/worktrees/1f2e" "$CODEX/worktrees/7c9a"
  G -C "$REPO" worktree add --detach "$CODEX/worktrees/1f2e/orbit-api" main
  G -C "$REPO" worktree add --detach "$CODEX/worktrees/7c9a/orbit-api" main
  printf 'work in progress\n' >> "$CODEX/worktrees/7c9a/orbit-api/README.md"
  touch "$DEV/.cleanups-seeded"
fi
if [ ! -f "$DEV/.models-seeded" ]; then
  # Local model stores from the fixtures: Ollama (a shared layer, an orphan and a partial
  # download), LM Studio, and a Hugging Face hub with a detached revision and a file two repos
  # share. Model blobs get some real bytes so sizes read like models; the stubs stand in for
  # the ollama and hf CLIs, so nothing reaches a real server or the network.
  rm -rf "$DEV/.ollama" "$DEV/.lmstudio" "$DEV/.cache/huggingface"
  cp -Rp "$ROOT/Tests/Fixtures/ollama/0.33/.ollama" "$DEV/.ollama"
  cp -Rp "$ROOT/Tests/Fixtures/lmstudio/0.3/.lmstudio" "$DEV/.lmstudio"
  mkdir -p "$DEV/.cache/huggingface" "$DEV/bin"
  cp -Rp "$ROOT/Tests/Fixtures/huggingface/1.x/hub" "$DEV/.cache/huggingface/hub"
  cp "$ROOT/Tests/Fixtures/ollama/stub-ollama.sh" "$DEV/bin/ollama"
  cp "$ROOT/Tests/Fixtures/huggingface/stub-hf.sh" "$DEV/bin/hf"
  chmod 755 "$DEV/bin/ollama" "$DEV/bin/hf"
  fill() { dd if=/dev/urandom of="$1" bs=1m count="$2" 2>/dev/null; }
  B="$DEV/.ollama/models/blobs"
  fill "$B/sha256-a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1" 48
  fill "$B/sha256-a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2" 36
  fill "$B/sha256-a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3" 8
  fill "$B/sha256-0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f" 12
  fill "$DEV/.lmstudio/models/lmstudio-community/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf" 30
  fill "$DEV/.lmstudio/models/bartowski/Llama-3.2-1B-Instruct-GGUF/Llama-3.2-1B-Instruct-Q8_0.gguf" 14
  fill "$DEV/.cache/huggingface/hub/blobs/11/1111111111111111111111111111111111111111111111111111111111111111" 9
  fill "$DEV/.cache/huggingface/hub/blobs/22/2222222222222222222222222222222222222222222222222222222222222222" 5
  fill "$DEV/.cache/huggingface/hub/models--acme--tiny-bert/blobs/b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2" 6
  age() { touch -h -t "$(date -v-"$1"d +%Y%m%d%H%M)" "$2"; }
  # Everything old first, then the dates the Disk screen shows.
  find "$DEV/.ollama" "$DEV/.lmstudio" "$DEV/.cache/huggingface" -exec touch -h -t "$(date -v-120d +%Y%m%d%H%M)" {} +
  M="$DEV/.ollama/models/manifests/registry.ollama.ai"
  age 92 "$M/library/qwen3/14b"; age 9 "$M/library/deepcoder/14b"; age 210 "$M/someuser/tinyllm/q4"
  age 5 "$DEV/.lmstudio/models/lmstudio-community/Qwen3-8B-GGUF/Qwen3-8B-Q4_K_M.gguf"
  age 5 "$DEV/.lmstudio/models/lmstudio-community/Qwen3-8B-GGUF"
  age 75 "$DEV/.lmstudio/models/bartowski/Llama-3.2-1B-Instruct-GGUF/Llama-3.2-1B-Instruct-Q8_0.gguf"
  age 75 "$DEV/.lmstudio/models/bartowski/Llama-3.2-1B-Instruct-GGUF"
  H="$DEV/.cache/huggingface/hub"
  age 70 "$H/models--acme--tiny-bert/snapshots/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  age 14 "$H/models--acme--tiny-bert-distilled/snapshots/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
  age 40 "$H/datasets--acme--reviews/snapshots/ffffffffffffffffffffffffffffffffffffffff"
  touch "$DEV/.models-seeded"
fi
if [ ! -f "$DEV/.gemini-seeded" ]; then
  # Gemini CLI and Antigravity from the fixtures. The chats' project paths point at folders in
  # .devhome/code, where the gemini stub (never the real CLI) runs --delete-session.
  rm -rf "$DEV/.gemini"
  cp -Rp "$ROOT/Tests/Fixtures/gemini/0.43" "$DEV/.gemini"
  cp -Rp "$ROOT/Tests/Fixtures/antigravity/1.5/antigravity-cli" "$DEV/.gemini/antigravity-cli"
  cp -Rp "$ROOT/Tests/Fixtures/antigravity/1.5/antigravity" "$DEV/.gemini/antigravity"
  mkdir -p "$DEV/bin" "$DEV/code/orbit-api" "$DEV/code/landing-site"
  cp "$ROOT/Tests/Fixtures/gemini/stub-gemini.sh" "$DEV/bin/gemini"
  chmod 755 "$DEV/bin/gemini"
  G="$DEV/.gemini"
  for f in "$G/projects.json" "$G/tmp/orbit-api/.project_root" "$G/tmp/landing-site/.project_root"; do
    sed "s|/Users/dev/code|$DEV/code|g" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
  # Compressible bulk, so Archive has something to do.
  seq 1 6000 | sed 's/.*/{"id":"b&","timestamp":"2026-11-21T10:01:00.000Z","type":"info","content":"synthetic repeated tool output for compression"}/' \
    >> "$G/tmp/orbit-api/chats/session-2026-11-21T10-00-7d7d7d7d.jsonl"
  for id in a1a1a1a1-1111-4111-8111-111111111111 b2b2b2b2-2222-4222-8222-222222222222; do
    mkdir -p "$G/antigravity-cli/conversations"
    sqlite3 "$G/antigravity-cli/conversations/$id.db" < "$ROOT/Tests/Fixtures/antigravity/sql/conversation.sql"
  done
  mkdir -p "$G/antigravity/conversations"
  sqlite3 "$G/antigravity/conversations/c3c3c3c3-3333-4333-8333-333333333333.db" < "$ROOT/Tests/Fixtures/antigravity/sql/conversation.sql"
  sqlite3 "$G/antigravity-cli/conversation_summaries.db" < "$ROOT/Tests/Fixtures/antigravity/sql/summaries.sql"
  dd if=/dev/urandom of="$G/antigravity-cli/log/cli-20261101_100000.log" bs=1k count=900 2>/dev/null
  dd if=/dev/urandom of="$G/antigravity-cli/brain/a1a1a1a1-1111-4111-8111-111111111111/screenshot.webp" bs=1k count=1500 2>/dev/null
  age() { touch -t "$(date -v-"$1"d +%Y%m%d%H%M)" "$2"; }
  C="$G/tmp/orbit-api/chats"
  age 2 "$C/session-2026-11-20T09-15-e1e1e1e1.jsonl"
  age 1 "$C/session-2026-11-21T10-00-7d7d7d7d.jsonl"
  age 26 "$C/session-2026-10-28T14-30-e3e3e3e3.jsonl"
  for f in "$G"/tmp/landing-site/chats/*.jsonl; do age 5 "$f"; done
  age 1 "$G/antigravity-cli/conversations/a1a1a1a1-1111-4111-8111-111111111111.db"
  age 3 "$G/antigravity-cli/conversations/b2b2b2b2-2222-4222-8222-222222222222.db"
  age 4 "$G/antigravity/conversations/c3c3c3c3-3333-4333-8333-333333333333.db"
  # The app store's presence lock is not held here, so its conversation shows as idle.
  touch "$DEV/.gemini-seeded"
fi
