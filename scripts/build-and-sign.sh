#!/bin/bash
# Builds Domovy.app (Release) with domo inside it, strips symbols and signs both.
#
# Usage: scripts/build-and-sign.sh [--install]
#   --install   also copy the app to /Applications (refused while Domovy is running).
#               Without it, /Applications is never touched.
#
# Environment:
#   SIGNING_IDENTITY  codesign identity. Default: the first "Apple Development" certificate in
#                     the keychain, else ad-hoc ("-"). A stable identity keeps macOS permission
#                     grants (Full Disk Access, Desktop/Documents/Downloads) across updates; ad-hoc
#                     mints a new identity every build and resets them. Set a "Developer ID
#                     Application" identity for a notarized release (see RELEASING.md).
#   TIMESTAMP=1       add a secure timestamp (needed for notarization; needs network).
#   MARKETING_VERSION, CURRENT_PROJECT_VERSION
#                     optional build-setting overrides (scripts/release.sh --dry-run uses them).
#
# The app ends up in .local/DerivedData/Build/Products/Release/Domovy.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

INSTALL=0
case "${1:-}" in
  --install) INSTALL=1 ;;
  "") ;;
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  *) echo "Unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

if [ -z "${SIGNING_IDENTITY:-}" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
  SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
fi
echo "Signing identity: $SIGNING_IDENTITY"

SIGN_FLAGS=(--force --sign "$SIGNING_IDENTITY" --options runtime)
if [ "${TIMESTAMP:-0}" = "1" ] && [ "$SIGNING_IDENTITY" != "-" ]; then
  SIGN_FLAGS+=(--timestamp)
fi

VERSION_SETTINGS=()
[ -n "${MARKETING_VERSION:-}" ] && VERSION_SETTINGS+=(MARKETING_VERSION="$MARKETING_VERSION")
[ -n "${CURRENT_PROJECT_VERSION:-}" ] && VERSION_SETTINGS+=(CURRENT_PROJECT_VERSION="$CURRENT_PROJECT_VERSION")

# Xcode signs ad-hoc here (no provisioning profile needed); the real signature comes below,
# after stripping. The "Embed domo" phase (scripts/embed-domo.sh) builds domo with SwiftPM for
# the same architectures and copies it to Contents/Helpers/domo.
echo "Building Domovy (Release)..."
xcodebuild -project Domovy.xcodeproj \
           -scheme Domovy \
           -configuration Release \
           -derivedDataPath .local/DerivedData \
           -destination 'generic/platform=macOS' \
           -quiet \
           CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual \
           ${VERSION_SETTINGS[@]+"${VERSION_SETTINGS[@]}"} \
           build

BUILT_APP=".local/DerivedData/Build/Products/Release/Domovy.app"
DOMO="$BUILT_APP/Contents/Helpers/domo"
[ -x "$DOMO" ] || { echo "error: $DOMO is missing; the Embed domo phase did not run" >&2; exit 1; }

# Strip symbol tables so the public build doesn't expose internal structure.
echo "Stripping symbols..."
strip -rSTx "$BUILT_APP/Contents/MacOS/Domovy" 2>/dev/null || true
strip -rSTx "$DOMO" 2>/dev/null || true

# Inside out: the helper first, then the app seals it. Hardened runtime, no entitlements
# (Domovy is not sandboxed and needs no exceptions).
echo "Signing domo..."
codesign "${SIGN_FLAGS[@]}" --identifier io.github.turman17.Domovy.domo "$DOMO"
echo "Signing Domovy..."
codesign "${SIGN_FLAGS[@]}" "$BUILT_APP"
codesign --verify --deep --strict "$BUILT_APP"
lipo -info "$DOMO"

if [ "$INSTALL" = "1" ]; then
  if pgrep -x Domovy >/dev/null; then
    echo "error: Domovy is running. Quit it, then run again with --install." >&2
    exit 1
  fi
  echo "Installing to /Applications..."
  rm -rf /Applications/Domovy.app
  ditto "$BUILT_APP" /Applications/Domovy.app
  /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/Domovy.app
  echo "Installed /Applications/Domovy.app"
else
  echo "Built and signed: $BUILT_APP"
fi
