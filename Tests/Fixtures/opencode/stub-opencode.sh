#!/bin/sh
# Stand-in for the opencode CLI, for tests and .devhome only. It never runs the real OpenCode
# and only touches $XDG_DATA_HOME/opencode/opencode.db. Like OpenCode 1.18.30 it prints its
# help to stderr. Markers in that opencode folder change its behaviour:
#   .stub-fail    session delete fails with exit status 1 and changes nothing
#   .stub-sloppy  session delete removes the session row but leaves its messages, parts and events
# Every invocation is appended to opencode/.stub-opencode.log.
set -eu
case "${1:-}" in
--version|-v) echo "1.18.30"; exit 0 ;;
--help|-h|"") echo "opencode (stub)" >&2; echo "  opencode session             manage sessions" >&2; exit 0 ;;
esac
data="${XDG_DATA_HOME:?XDG_DATA_HOME must be set}/opencode"
echo "$*" >> "$data/.stub-opencode.log"
db="$data/opencode.db"
case "${1:-} ${2:-}" in
"session --help"|"session -h"|"session ")
  cat >&2 <<'HELP'
opencode session

manage sessions

Commands:
  opencode session list                list sessions
  opencode session delete <sessionID>  delete a session
HELP
  ;;
"session delete")
  id="${3:?session id}"
  if [ -f "$data/.stub-fail" ]; then echo "Error: stub failure" >&2; exit 1; fi
  [ -n "$(sqlite3 "$db" "select id from session where id = '$id'")" ] || { echo "Session not found: $id" >&2; exit 1; }
  if [ -f "$data/.stub-sloppy" ]; then
    sqlite3 "$db" "delete from session where id = '$id';"
  else
    sqlite3 "$db" "delete from part where session_id = '$id'; delete from message where session_id = '$id'; delete from event where aggregate_id = '$id'; delete from event_sequence where aggregate_id = '$id'; delete from session where id = '$id';"
  fi
  echo "Session $id deleted" ;;
*)
  echo "Error: the stub does not implement '$*'" >&2; exit 2 ;;
esac
