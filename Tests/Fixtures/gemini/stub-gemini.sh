#!/bin/sh
# Stand-in for the gemini CLI, for tests and .devhome only. It never runs the real Gemini CLI
# and only touches files under $GEMINI_CLI_HOME/.gemini. Like Gemini CLI 0.43.0, it finds the
# project from the working directory and deletes every chat whose name ends in the first 8
# characters of the id, plus the files keyed by the id. Markers in that .gemini folder:
#   .stub-fail    --delete-session fails with exit status 1
#   .stub-sloppy  only the chat file goes; logs, tool outputs and folders stay
#   .stub-sweep   also deletes the project's oldest other chat, like Gemini's own cleanup
# Every invocation is appended to .gemini/.stub-gemini.log.
set -eu
# Help works anywhere; anything else needs the home Domovy passes.
case "${1:-}" in --help|-h|--version|-v|"") ;; *) : "${GEMINI_CLI_HOME:?GEMINI_CLI_HOME must be set}" ;; esac
home="${GEMINI_CLI_HOME:-}/.gemini"
[ -z "${GEMINI_CLI_HOME:-}" ] || echo "$* (in $(pwd))" >> "$home/.stub-gemini.log"

case "${1:-}" in
--version|-v)
  echo "0.43.0" ;;
--help|-h|"")
  cat <<'EOF'
Usage: gemini [options] [command]

Options:
      --list-sessions             List available sessions for the current project and exit.  [boolean]
      --delete-session            Delete a session by index number (use --list-sessions to see available sessions).  [string]
  -v, --version                   Show version number  [boolean]
EOF
  ;;
--delete-session)
  id="${2:?session id}"
  if [ -f "$home/.stub-fail" ]; then echo "Failed to delete session: stub failure" >&2; exit 1; fi
  project=""
  for marker in "$home"/tmp/*/.project_root; do
    root="$(cd "$(cat "$marker")" 2>/dev/null && pwd -P || true)"
    [ -n "$root" ] && [ "$root" = "$(pwd -P)" ] && project="$(dirname "$marker")"
  done
  [ -n "$project" ] || { echo "No sessions found for this project." >&2; exit 0; }
  found=""
  for chat in "$project"/chats/session-*.json*; do
    [ -f "$chat" ] || continue
    head -n 1 "$chat" | grep -q "\"sessionId\":\"$id\"" && found="$chat"
  done
  # Gemini CLI exits 0 even when it cannot find the session.
  [ -n "$found" ] || { echo "Invalid session identifier \"$id\". Use --list-sessions to see available sessions." >&2; exit 0; }
  short="$(echo "$id" | cut -c1-8)"
  if [ -f "$home/.stub-sweep" ]; then
    oldest="$(ls -tr "$project"/chats/session-*.json* | grep -v -- "-$short.json" | head -n 1 || true)"
    [ -n "$oldest" ] && rm -f "$oldest"
  fi
  rm -f "$project"/chats/session-*-"$short".json "$project"/chats/session-*-"$short".jsonl
  if [ ! -f "$home/.stub-sloppy" ]; then
    rm -rf "$project/chats/$id" "$project/logs/session-$id.jsonl" "$project/tool-outputs/session-$id" "$project/$id"
  fi
  echo "Deleted session 1: (stub)" ;;
*)
  echo "Error: the stub does not implement '$1'" >&2; exit 2 ;;
esac
