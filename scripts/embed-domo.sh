#!/bin/bash
# Xcode Run Script phase of the Domovy target: builds the domo CLI with SwiftPM for the same
# configuration and architectures, copies it to Domovy.app/Contents/Helpers/domo and signs it
# with the app's identity, so Connect Agents always has a domo to register (Debug included).
#
# SwiftPM builds incrementally in .build/, the same folder `make cli` and `swift test` use, so
# an unchanged domo costs a second or two. scripts/release.sh passes DOMO_BINARY (its own
# universal, Developer ID signed build) and this phase copies that instead of building again.
set -euo pipefail

HELPERS="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
DEST="$HELPERS/domo"
mkdir -p "$HELPERS"

if [ -n "${DOMO_BINARY:-}" ]; then
  SOURCE="$DOMO_BINARY"
else
  case "$CONFIGURATION" in
    Release) SWIFT_CONFIG=release ;;
    *) SWIFT_CONFIG=debug ;;
  esac
  HOST_ARCH="$(uname -m)"
  ARCH_FLAGS=()
  # One native arch builds in the shared .build/<triple>/ folder; anything else asks for each arch.
  if [ "$ARCHS" != "$HOST_ARCH" ]; then
    for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
  fi
  # Xcode's build settings (SDKROOT, deployment target, toolchain variables) would make SwiftPM
  # rebuild from scratch or fail, so run it with a clean environment.
  build() {
    env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" DEVELOPER_DIR="$DEVELOPER_DIR" TMPDIR="${TMPDIR:-/tmp}" \
      xcrun swift build --package-path "$SRCROOT" -c "$SWIFT_CONFIG" --product domo ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} "$@"
  }
  mkdir -p "$DERIVED_FILE_DIR"
  LOG="$DERIVED_FILE_DIR/domo-build.log"
  if ! build > "$LOG" 2>&1; then
    grep -E "error:" "$LOG" >&2 || cat "$LOG" >&2
    echo "error: building domo failed; full log in $LOG" >&2
    exit 1
  fi
  BIN="$(build --show-bin-path)"
  SOURCE="$BIN/domo"
fi

[ -x "$SOURCE" ] || { echo "error: domo was not built at $SOURCE" >&2; exit 1; }

# Copy and re-sign only when the binary changed: signing rewrites the copy, so compare against
# the unsigned build kept in DERIVED_FILE_DIR.
STAMP="$DERIVED_FILE_DIR/domo.unsigned"
if [ -f "$DEST" ] && cmp -s "$SOURCE" "$STAMP"; then
  exit 0
fi
mkdir -p "$DERIVED_FILE_DIR"
cp -f "$SOURCE" "$DEST"
IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -n "$IDENTITY" ] || IDENTITY="-"
# shellcheck disable=SC2086 # OTHER_CODE_SIGN_FLAGS is a list of flags
codesign --force --sign "$IDENTITY" --identifier "$PRODUCT_BUNDLE_IDENTIFIER.domo" --options runtime ${OTHER_CODE_SIGN_FLAGS:-} "$DEST"
cp -f "$SOURCE" "$STAMP"
echo "Embedded domo in $DEST"
