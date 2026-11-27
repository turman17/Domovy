# Releasing Domovy

A release is `Domovy-v<version>.zip` (and optionally a `.dmg`) on GitHub Releases, plus the cask
in the [`turman17/tap`](https://github.com/turman17/homebrew-tap) Homebrew tap. The `domo` CLI
ships inside the app (`Contents/Helpers/domo`); the cask links it onto `PATH`.

Domovy is published the same way as FinderConvert: **signed, not notarized**. Signing uses the
first "Apple Development" certificate in the keychain (or `SIGNING_IDENTITY`). A stable identity
keeps Full Disk Access and folder permissions across updates. Users clear the quarantine flag
once (`xattr -dr com.apple.quarantine /Applications/Domovy.app`); the cask's caveats say so.

## Each release

1. Add the version's entry to `CHANGELOG.md` (`## [1.0.0] - date`); it becomes the release notes.
2. `swift test` and `make app`.
3. Check the pipeline without touching any file or GitHub:
   ```sh
   DMG=1 scripts/release.sh 1.0.0 --dry-run
   ```
4. Cut it:
   ```sh
   DMG=1 scripts/release.sh 1.0.0
   ```
   It stamps `MARKETING_VERSION`, bumps `CURRENT_PROJECT_VERSION`, stamps `DomovyVersion.swift`
   (`domo --version`, MCP server version), runs `scripts/build-and-sign.sh`, zips with `ditto`
   into `.local/release/`, prints the sha256 and the cask stanza, and updates
   `packaging/homebrew/domovy.rb` (a filled copy also lands in `.local/release/domovy.rb`).
5. Before answering the y/N prompt, commit and push the version stamp: `gh release create` tags
   the remote default branch. Answering `y` publishes the release with the CHANGELOG notes.
6. Copy `.local/release/domovy.rb` to `Casks/domovy.rb` in `turman17/homebrew-tap`, push, then:
   ```sh
   brew audit --cask turman17/tap/domovy
   brew install --cask turman17/tap/domovy && domo --version
   ```
   The script never pushes the tap.

The repository must be public before Homebrew users can download the zip.

## Scripts

- `scripts/build-and-sign.sh [--install]` — Release build into `.local/DerivedData`, `domo`
  embedded by the Xcode "Embed domo" phase (`scripts/embed-domo.sh`), symbols stripped, `domo`
  and the app signed with the hardened runtime and no entitlements. `--install` copies the app
  to `/Applications` (refused while Domovy runs); without it `/Applications` is never touched.
- `scripts/create-dmg.sh <app> <dmg>` — disk image with an Applications link; uses
  `create-dmg` when installed, `hdiutil` otherwise.
- `scripts/release.sh <version> [--dry-run]` — the steps above.

## Optional: notarized releases

If a paid Apple Developer account becomes available, the same scripts notarize:

1. Create a *Developer ID Application* certificate (Xcode > Settings > Accounts > Manage
   Certificates) and save notarization credentials once:
   ```sh
   xcrun notarytool store-credentials domovy-notary \
     --apple-id you@example.com --team-id ABCDE12345 --password <app-specific-password>
   ```
2. Release with:
   ```sh
   SIGNING_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" \
   NOTARY_PROFILE=domovy-notary DMG=1 scripts/release.sh 1.1.0
   ```
   Signatures get a secure timestamp, the app (and dmg) are notarized and stapled before
   packaging. Then drop the `xattr` lines from the cask caveats and the README.

Note: changing the signing identity (Apple Development to Developer ID) makes macOS treat the
app as new once; users grant Full Disk Access again.

## Notes

- The cask's `zap` removes only Domovy's preferences and saved window state. It keeps
  `~/Library/Application Support/Domovy`: the quarantine and undo log may hold the only copy of
  sessions a user set aside.
- Neither the cask nor the app changes agent configs on its own; the caveats suggest `domo install`.
