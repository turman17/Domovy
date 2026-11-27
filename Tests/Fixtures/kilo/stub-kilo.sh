#!/bin/sh
# Stand-in for the kilo CLI (Kilo Code 7.8), for tests and .devhome only. It never runs the real
# Kilo and only touches $KILO_DB. Like Kilo-Org/kilocode@bfdec549:
#   packages/opencode/src/cli/cmd/session.ts#L50-L71: `session` has `list` and `delete <sessionID>`,
#     printing "Session <id> deleted" or failing with "Session not found: <id>";
#   packages/opencode/src/session/session.ts#L723-L726: delete removes child sessions first;
#   packages/core/src/session/sql.ts#L73-L114: message and part rows cascade with their session.
# Markers next to the database: .stub-fail makes delete fail and change nothing.
# Every invocation is appended to .stub-kilo.log next to the database.
set -eu
case "${1:-}" in
--version|-v) echo "7.8.32"; exit 0 ;;
--help|-h|"") echo "kilo (stub)"; exit 0 ;;
esac
db="${KILO_DB:?KILO_DB must be set}"
data="$(dirname "$db")"
echo "$*" >> "$data/.stub-kilo.log"
remove() {
  for child in $(sqlite3 "$db" "select id from session where parent_id = '$1'"); do remove "$child"; done
  sqlite3 "$db" "delete from part where session_id = '$1'; delete from message where session_id = '$1'; delete from event where aggregate_id = '$1'; delete from event_sequence where aggregate_id = '$1'; delete from session where id = '$1';"
}
case "${1:-} ${2:-}" in
"session --help"|"session -h"|"session ")
  cat <<'HELP'
kilo session

manage sessions

Commands:
  kilo session list              list sessions
  kilo session delete <sessionID>  delete a session
HELP
  ;;
"session delete")
  id="${3:?session id}"
  if [ -f "$data/.stub-fail" ]; then echo "Error: stub failure" >&2; exit 1; fi
  [ -n "$(sqlite3 "$db" "select id from session where id = '$id'")" ] || { echo "Session not found: $id" >&2; exit 1; }
  remove "$id"
  echo "Session $id deleted" ;;
*)
  echo "Error: the stub does not implement '$*'" >&2; exit 2 ;;
esac
