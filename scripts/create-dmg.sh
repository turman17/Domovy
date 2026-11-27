#!/bin/bash
# Packs a built Domovy.app into a disk image with an Applications shortcut.
#
# Usage: scripts/create-dmg.sh <Domovy.app> <output.dmg>
#
# Uses the `create-dmg` tool (brew install create-dmg) for a laid-out window when it is
# installed, plain hdiutil otherwise. Signs the image when SIGNING_IDENTITY is a real identity.
set -euo pipefail

APP="${1:?usage: scripts/create-dmg.sh <Domovy.app> <output.dmg>}"
DMG="${2:?usage: scripts/create-dmg.sh <Domovy.app> <output.dmg>}"
[ -d "$APP" ] || { echo "error: $APP not found" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Domovy.app"
rm -f "$DMG"

echo "Creating $DMG..."
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "Domovy" \
    --window-pos 200 200 \
    --window-size 660 400 \
    --icon-size 96 \
    --icon "Domovy.app" 190 180 \
    --app-drop-link 470 180 \
    --hide-extension "Domovy.app" \
    --no-internet-enable \
    "$DMG" "$STAGING" >/dev/null
else
  ln -s /Applications "$STAGING/Applications"
  hdiutil create -volname "Domovy" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
fi

if [ -n "${SIGNING_IDENTITY:-}" ] && [ "$SIGNING_IDENTITY" != "-" ]; then
  codesign --force --sign "$SIGNING_IDENTITY" "$DMG"
fi
echo "Created $DMG"
