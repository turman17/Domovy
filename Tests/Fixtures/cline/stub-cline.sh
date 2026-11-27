#!/bin/sh
# Stand-in for the cline CLI, for tests and .devhome only. It never runs the real Cline and only
# touches $CLINE_DATA_DIR. Like cline/cline@34c104e6 apps/cli/src/commands/history-command.ts#L63-L76
# and sdk/packages/core/src/session/services/persistence-service.ts#L586-L645: `history delete
# --session-id <id>` never prompts, deletes the row and its child rows, and removes the session folder.
# A .stub-fail marker in the data dir makes delete fail. Calls go to $CLINE_DATA_DIR/.stub-cline.log.
set -eu
data="${CLINE_DATA_DIR:?CLINE_DATA_DIR must be set}"
case "${1:-} ${2:-}" in
"history --help") printf 'Usage: cline history [options] [command]\n\nCommands:\n  delete [options]  Delete a session from history\n'; exit 0 ;;
"history delete") ;;
*) echo "Error: the stub does not implement '$*'" >&2; exit 2 ;;
esac
[ "${3:-}" = "--session-id" ] || { echo "history delete requires --session-id <id>" >&2; exit 1; }
id="$4"; db="$data/db/sessions.db"
echo "history delete $id" >> "$data/.stub-cline.log"
if [ -f "$data/.stub-fail" ]; then echo "Error: stub failure" >&2; exit 1; fi
[ -n "$(sqlite3 "$db" "select session_id from sessions where session_id = '$id'")" ] || { echo "Session not found" >&2; exit 1; }
for child in $(sqlite3 "$db" "select session_id from sessions where parent_session_id = '$id'"); do rm -rf "$data/sessions/$child"; done
sqlite3 "$db" "delete from sessions where parent_session_id = '$id'; delete from sessions where session_id = '$id';"
rm -rf "$data/sessions/$id"
echo "Deleted"
