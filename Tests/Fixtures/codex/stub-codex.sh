#!/bin/sh
# Stand-in for the codex CLI, for tests and .devhome only. It never runs the real Codex and
# only touches files under $CODEX_HOME. Markers in $CODEX_HOME change its behaviour:
#   .stub-fail    every mutating command fails with exit status 1
#   .stub-sloppy  delete removes the rollout but leaves index lines and database rows
# Every invocation is appended to $CODEX_HOME/.stub-codex.log.
set -eu
home="${CODEX_HOME:?CODEX_HOME must be set}"
echo "$*" >> "$home/.stub-codex.log"

rollouts() { find "$home/sessions" "$home/archived_sessions" -type f -name "rollout-*-$1*.jsonl*" 2>/dev/null; }
fail_if_asked() { if [ -f "$home/.stub-fail" ]; then echo "Error: failed to $1 session" >&2; exit 1; fi; }

case "${1:-}" in
--version)
  echo "codex-cli 0.169.0 (stub)" ;;
--help|help|"")
  cat <<'EOF'
Codex CLI (stub)

Commands:
  archive           Archive a saved session by id or session name
  delete            Permanently delete a saved session by id or session name
  unarchive         Unarchive a saved session by id or session name
  help              Print this message or the help of the given subcommand(s)
EOF
  ;;
delete)
  fail_if_asked delete
  [ "${2:-}" = "--force" ] || { echo "Error: cannot confirm session deletion without an interactive terminal" >&2; exit 1; }
  id="${3:?session id}"
  files="$(rollouts "$id")"
  [ -n "$files" ] || { echo "Error: no saved session $id" >&2; exit 1; }
  echo "$files" | while IFS= read -r f; do rm -f "$f"; done
  if [ ! -f "$home/.stub-sloppy" ]; then
    if [ -f "$home/session_index.jsonl" ]; then
      grep -v "\"id\":\"$id\"" "$home/session_index.jsonl" > "$home/.stub-index" || true
      cat "$home/.stub-index" > "$home/session_index.jsonl"; rm -f "$home/.stub-index"
    fi
    for db in "$home/state_5.sqlite" "$home/thread_history_1.sqlite"; do
      [ -f "$db" ] || continue
      for t in $(sqlite3 "$db" "select name from sqlite_master where type='table'"); do
        for c in id thread_id parent_thread_id child_thread_id; do
          sqlite3 "$db" "delete from $t where $c = '$id'" 2>/dev/null || true
        done
      done
    done
  fi
  echo "Deleted session $id" ;;
archive)
  fail_if_asked archive
  id="${2:?session id}"
  files="$(find "$home/sessions" -type f -name "rollout-*-$id*.jsonl*")"
  [ -n "$files" ] || { echo "Error: no active session $id" >&2; exit 1; }
  mkdir -p "$home/archived_sessions"
  echo "$files" | while IFS= read -r f; do mv "$f" "$home/archived_sessions/"; done
  echo "Archived session $id" ;;
unarchive)
  fail_if_asked unarchive
  id="${2:?session id}"
  for f in $(find "$home/archived_sessions" -type f -name "rollout-*-$id*.jsonl*"); do
    name="$(basename "$f")"
    day="$(echo "$name" | sed -E 's/^rollout-([0-9]{4})-([0-9]{2})-([0-9]{2})T.*/\1\/\2\/\3/')"
    mkdir -p "$home/sessions/$day"
    mv "$f" "$home/sessions/$day/"
  done
  echo "Unarchived session $id" ;;
*)
  echo "Error: the stub does not implement '$1'" >&2; exit 2 ;;
esac
