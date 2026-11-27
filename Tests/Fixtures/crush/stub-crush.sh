#!/bin/sh
# Stand-in for the crush CLI, for tests and .devhome only. It never runs the real Crush and only
# touches <data-dir>/crush.db. Like charmbracelet/crush@ee51fe87 internal/cmd/session.go#L71-L78,
# #L293-L327 and internal/session/session.go#L147-L178: `session delete <id>` (alias rm) never
# prompts and deletes the session's messages, files and row, but not its child sessions.
# A .stub-fail marker in the data dir makes delete fail. Calls are logged to <data-dir>/.stub-crush.log.
set -eu
[ "${1:-}" = "session" ] || { echo "crush (stub)"; exit 0; }
case "${2:-}" in
--help|-h|"")
  printf 'Manage Crush sessions.\n\nAvailable Commands:\n  delete      Delete a session\n  list        List all sessions\n'; exit 0 ;;
delete|rm) ;;
*) echo "Error: the stub does not implement '$*'" >&2; exit 2 ;;
esac
id="$3"; shift 3; dir=""
while [ $# -gt 0 ]; do case "$1" in --data-dir|-D) dir="$2"; shift 2 ;; --cwd|-c) shift 2 ;; *) shift ;; esac; done
db="${dir:?--data-dir must be set}/crush.db"
echo "session delete $id" >> "$dir/.stub-crush.log"
if [ -f "$dir/.stub-fail" ]; then echo "Error: stub failure" >&2; exit 1; fi
[ -n "$(sqlite3 "$db" "select id from sessions where id = '$id'")" ] || { echo "Error: session not found: $id" >&2; exit 1; }
sqlite3 "$db" "PRAGMA foreign_keys=ON; delete from messages where session_id = '$id'; delete from files where session_id = '$id'; delete from sessions where id = '$id';"
echo "Deleted session ${id%%-*}"
