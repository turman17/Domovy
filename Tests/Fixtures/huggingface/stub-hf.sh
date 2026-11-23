#!/bin/sh
# Stand-in for the hf CLI (huggingface_hub), for tests and .devhome only. It never downloads
# anything and only touches files under $HF_HUB_CACHE. Markers in $HF_HUB_CACHE:
#   .stub-sloppy  cache rm leaves the repo folder; cache prune leaves detached snapshots
#   .stub-fail    every mutating command fails with exit status 1
# Every invocation is appended to $HF_HUB_CACHE/.stub-hf.log.
set -eu
hub="${HF_HUB_CACHE:?HF_HUB_CACHE must be set}"
echo "$*" >> "$hub/.stub-hf.log"
fail_if_asked() { if [ -f "$hub/.stub-fail" ]; then echo "Error: could not $1" >&2; exit 1; fi; }

# Removes shared-store files that no repo blob links to any more.
sweep_store() {
  for f in $(find "$hub/blobs" -mindepth 2 -type f ! -name '*.refs' ! -name '*.lock' 2>/dev/null); do
    rel="blobs/${f#$hub/blobs/}"
    if ! find "$hub" -path "$hub/blobs" -prune -o -type l -print 2>/dev/null | while IFS= read -r l; do readlink "$l"; done | grep -q "$rel"; then
      rm -f "$f" "$f.refs" "$f.lock"
    fi
  done
}

case "${1:-} ${2:-}" in
"--version "*)
  echo "huggingface_hub version: 1.2.0 (stub)" ;;
"cache --help"|"cache ")
  cat <<'HELP'
 Usage: hf cache [OPTIONS] COMMAND [ARGS]...

 Manage local cache directory.

╭─ Commands ──────────────────────────────────────────────╮
│ ls      List cached repositories or revisions.          │
│ rm      Remove cached repositories or revisions.        │
│ prune   Remove detached revisions from the cache.       │
│ verify  Verify checksums for a single repo revision.    │
╰─────────────────────────────────────────────────────────╯
HELP
  ;;
"cache rm")
  fail_if_asked "remove the repo"
  repo="${3:?repo}"
  type="${repo%%/*}"; id="${repo#*/}"
  dir="$hub/${type}s--$(printf '%s' "$id" | sed 's|/|--|g')"
  [ -d "$dir" ] || { echo "Error: $repo is not in the cache" >&2; exit 1; }
  if [ -f "$hub/.stub-sloppy" ]; then rm -rf "$dir/refs"; else rm -rf "$dir" "$hub/.locks/$(basename "$dir")"; sweep_store; fi
  echo "Deleted $repo" ;;
"cache prune")
  fail_if_asked "prune the cache"
  [ -f "$hub/.stub-sloppy" ] && { echo "Nothing to prune."; exit 0; }
  for dir in "$hub"/*--*--*; do
    [ -d "$dir/snapshots" ] || continue
    refs="$(cat "$dir"/refs/* 2>/dev/null || true)"
    for snap in "$dir"/snapshots/*; do
      rev="$(basename "$snap")"
      echo "$refs" | grep -q "$rev" || rm -rf "$snap" "$dir/.no_exist/$rev"
    done
    for b in "$dir"/blobs/*; do
      [ -e "$b" ] || [ -L "$b" ] || continue
      name="$(basename "$b")"
      find "$dir/snapshots" -type l | while IFS= read -r l; do readlink "$l"; done | grep -q "$name" || rm -f "$b"
    done
  done
  sweep_store
  echo "Pruned detached revisions." ;;
*)
  echo "Error: the stub does not implement '$*'" >&2; exit 2 ;;
esac
