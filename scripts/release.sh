#!/bin/bash
# Cut a release: stamp the version, build and sign, produce the zip (and dmg), compute the
# cask sha256, and (with gh installed, after a y/N prompt) publish a GitHub release.
#
# Usage:
#   scripts/release.sh 1.0.0             stamp, build, package, then ask before `gh release create`
#   scripts/release.sh 1.0.0 --dry-run   build, sign and package without stamping any file and
#                                        without calling gh (check the pipeline)
#
# Environment:
#   SIGNING_IDENTITY  as in scripts/build-and-sign.sh (default: first Apple Development identity)
#   DMG=1             also build Domovy-v<version>.dmg
#   NOTARY_PROFILE    optional: a keychain profile saved with `xcrun notarytool store-credentials`.
#                     Only with a "Developer ID Application" SIGNING_IDENTITY. When set, the app
#                     (and dmg) are notarized and stapled, and users need no xattr step.
#
# Output in .local/release/. The tap (turman17/homebrew-tap) is never pushed from here: copy
# .local/release/domovy.rb to Casks/domovy.rb there yourself (see RELEASING.md).
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version, e.g. 1.0.0> [--dry-run]}"
DRY_RUN=0
case "${2:-}" in
  --dry-run) DRY_RUN=1 ;;
  "") ;;
  *) echo "Unknown option: $2" >&2; exit 2 ;;
esac
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: version must look like 1.0.0" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PBXPROJ="Domovy.xcodeproj/project.pbxproj"
VERSION_SWIFT="Sources/DomovyCore/Support/DomovyVersion.swift"

if [ -z "${SIGNING_IDENTITY:-}" ]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ {print $2; exit}')"
  SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
fi
export SIGNING_IDENTITY

if [ -n "${NOTARY_PROFILE:-}" ]; then
  [[ "$SIGNING_IDENTITY" == "Developer ID Application:"* ]] \
    || { echo "error: NOTARY_PROFILE needs a \"Developer ID Application\" SIGNING_IDENTITY (got: $SIGNING_IDENTITY)" >&2; exit 1; }
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || { echo "error: notarytool cannot use the keychain profile \"$NOTARY_PROFILE\"" >&2; exit 1; }
  export TIMESTAMP=1
fi

BUILD=$(( $(awk -F' = |;' '/CURRENT_PROJECT_VERSION = /{print $2; exit}' "$PBXPROJ") + 1 ))
if [ "$DRY_RUN" = "1" ]; then
  echo "==> Dry run: version $VERSION (build $BUILD) passed to xcodebuild, no file stamped"
  export MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD"
  grep -q "current = \"$VERSION\"" "$VERSION_SWIFT" \
    || echo "warning: $VERSION_SWIFT has another version; domo --version will not say $VERSION"
else
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then
    echo "error: tag v$VERSION already exists" >&2
    exit 1
  fi
  echo "==> Stamping version $VERSION (build $BUILD)"
  sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
  sed -i '' "s/CURRENT_PROJECT_VERSION = [^;]*;/CURRENT_PROJECT_VERSION = $BUILD;/g" "$PBXPROJ"
  sed -i '' "s/current = \"[^\"]*\"/current = \"$VERSION\"/" "$VERSION_SWIFT"
fi

echo "==> Building and signing"
bash scripts/build-and-sign.sh

BUILT_APP="$ROOT/.local/DerivedData/Build/Products/Release/Domovy.app"
OUT="$ROOT/.local/release"
mkdir -p "$OUT"
ZIP="$OUT/Domovy-v$VERSION.zip"
DMG_PATH="$OUT/Domovy-v$VERSION.dmg"

notarize() { # notarize <file>
  echo "==> Notarizing $(basename "$1")"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m
}

if [ -n "${NOTARY_PROFILE:-}" ]; then
  ditto -c -k --keepParent "$BUILT_APP" "$OUT/notarize.zip"
  notarize "$OUT/notarize.zip"
  rm "$OUT/notarize.zip"
  xcrun stapler staple "$BUILT_APP"
fi

echo "==> Packaging $ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$BUILT_APP" "$ZIP"
ASSETS=("$ZIP")

if [ "${DMG:-0}" = "1" ]; then
  bash scripts/create-dmg.sh "$BUILT_APP" "$DMG_PATH"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    notarize "$DMG_PATH"
    xcrun stapler staple "$DMG_PATH"
  fi
  ASSETS+=("$DMG_PATH")
fi

SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
CASK="$OUT/domovy.rb"
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" \
  packaging/homebrew/domovy.rb > "$CASK"
[ "$DRY_RUN" = "1" ] || cp "$CASK" packaging/homebrew/domovy.rb

echo ""
for asset in "${ASSETS[@]}"; do
  echo "Artifact:  ${asset#"$ROOT"/} ($(du -h "$asset" | awk '{print $1}'), sha256 $(shasum -a 256 "$asset" | awk '{print $1}'))"
done
echo ""
echo "Cask stanza for homebrew-tap/Casks/domovy.rb (full file: ${CASK#"$ROOT"/}):"
echo "  version \"$VERSION\""
echo "  sha256 \"$SHA256\""
echo ""

if [ "$DRY_RUN" = "1" ]; then
  echo "Dry run: nothing published."
  exit 0
fi

if command -v gh >/dev/null 2>&1; then
  if [ "$(gh repo view --json visibility --jq .visibility 2>/dev/null)" = "PRIVATE" ]; then
    echo "Note: the repository is private, so Homebrew and other users cannot download the release yet."
  fi
  NOTES="$OUT/notes.md"
  awk -v v="$VERSION" '$0 ~ "^## \\[?"v"\\]?" {on=1; next} on && /^## / {exit} on' CHANGELOG.md > "$NOTES" 2>/dev/null || true
  echo "gh tags the remote default branch: commit and push the version stamp first (git status)."
  read -r -p "Create GitHub release v$VERSION and upload ${#ASSETS[@]} file(s)? [y/N] " REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    if [ -s "$NOTES" ]; then
      gh release create "v$VERSION" "${ASSETS[@]}" --title "Domovy $VERSION" --notes-file "$NOTES"
    else
      gh release create "v$VERSION" "${ASSETS[@]}" --title "Domovy $VERSION" --generate-notes
    fi
    echo "Release published. Copy ${CASK#"$ROOT"/} to Casks/domovy.rb in turman17/homebrew-tap."
  fi
else
  echo "gh CLI not found — create the GitHub release manually and attach the files above."
fi
