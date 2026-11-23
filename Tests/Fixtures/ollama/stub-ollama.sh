#!/bin/sh
# Stand-in for the ollama CLI, for tests and .devhome only. It never talks to a real Ollama
# server and only touches files under $OLLAMA_MODELS. Markers in $OLLAMA_MODELS:
#   .stub-server-down  every command fails as if the server were not running
#   .stub-loaded       model names `ollama ps` lists as loaded, one per line
#   .stub-sloppy       rm removes the manifest but leaves the unshared blobs
#   .stub-fail         rm fails with exit status 1
# Every invocation is appended to $OLLAMA_MODELS/.stub-ollama.log.
set -eu
home="${OLLAMA_MODELS:?OLLAMA_MODELS must be set}"
echo "$*" >> "$home/.stub-ollama.log"
down() { if [ -f "$home/.stub-server-down" ]; then echo "Error: could not connect to ollama server, run 'ollama serve' to start it" >&2; exit 1; fi; }

manifest_of() {
  name="$1"
  case "$name" in *:*) tag="${name##*:}"; base="${name%:*}" ;; *) tag=latest; base="$name" ;; esac
  case "$(printf '%s' "$base" | tr -cd / | wc -c | tr -d ' ')" in
    0) echo "$home/manifests/registry.ollama.ai/library/$base/$tag" ;;
    1) echo "$home/manifests/registry.ollama.ai/$base/$tag" ;;
    *) echo "$home/manifests/$base/$tag" ;;
  esac
}

case "${1:-}" in
--version|-v)
  down; echo "ollama version is 0.33.3 (stub)" ;;
--help|help|"")
  cat <<'HELP'
Large language model runner (stub)

Available Commands:
  list         List models
  ps           List running models
  rm           Remove a model
HELP
  ;;
ps)
  down
  echo "NAME    ID    SIZE    PROCESSOR    UNTIL"
  if [ -f "$home/.stub-loaded" ]; then
    while IFS= read -r m; do [ -n "$m" ] && echo "$m    abc123def456    9.3 GB    100% GPU    4 minutes from now"; done < "$home/.stub-loaded"
  fi ;;
list)
  down
  echo "NAME    ID    SIZE    MODIFIED"
  find "$home/manifests" -type f | sed "s|$home/manifests/||" ;;
rm)
  down
  if [ -f "$home/.stub-fail" ]; then echo "Error: failed to remove model" >&2; exit 1; fi
  shift
  for name in "$@"; do
    m="$(manifest_of "$name")"
    [ -f "$m" ] || { echo "Error: model '$name' not found" >&2; exit 1; }
    digests="$(grep -o 'sha256:[0-9a-f]\{64\}' "$m" | sed 's/sha256:/sha256-/' | sort -u)"
    rm -f "$m"
    if [ ! -f "$home/.stub-sloppy" ]; then
      for d in $digests; do
        hex="${d#sha256-}"
        if ! grep -rqs "sha256:$hex" "$home/manifests"; then rm -f "$home/blobs/$d"; fi
      done
    fi
    echo "deleted '$name'"
  done ;;
*)
  echo "Error: the stub does not implement '$1'" >&2; exit 2 ;;
esac
