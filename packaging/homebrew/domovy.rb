# Homebrew cask for Domovy.
#
# This file lives in the app repo as the template of record. To publish, copy it into the
# tap repository turman17/homebrew-tap at Casks/domovy.rb. Users then install with:
#
#   brew install --cask turman17/tap/domovy
#
# scripts/release.sh <version> updates `version` and `sha256` here and writes the same file to
# .local/release/domovy.rb. The app carries the domo CLI, so there is no separate formula.
cask "domovy" do
  version "1.0.0"
  sha256 "f1ff4aa9ed74e85696f1fd2c6b547225e355f96753a697666ba908938587e32f"

  url "https://github.com/turman17/Domovy/releases/download/v#{version}/Domovy-v#{version}.zip"
  name "Domovy"
  desc "Tidy up after AI coding agents: sessions, archives and disk space"
  homepage "https://github.com/turman17/Domovy"

  depends_on macos: :sonoma

  app "Domovy.app"
  binary "#{appdir}/Domovy.app/Contents/Helpers/domo"

  caveats <<~EOS
    Domovy is not notarized (no paid Apple Developer account).
    After installing, clear the quarantine flag once:

      xattr -dr com.apple.quarantine /Applications/Domovy.app

    Domovy changes no agent configuration on its own. To let your AI agents
    list and tidy their sessions through Domovy (MCP server and skill), run:

      domo install

    or use Domovy > Connect Agents... in the app. `domo disconnect --all`
    removes it again.

    Full Disk Access is optional (System Settings > Privacy & Security >
    Full Disk Access). Domovy works without it; with it, Domovy can also
    measure the few agents that keep data in folders macOS protects.
  EOS

  # Only Domovy's own preferences and window state. ~/Library/Application Support/Domovy is
  # left alone on purpose, even by `brew uninstall --zap`: it holds the quarantine folder and
  # the undo log, which may be the only copy of sessions the user set aside.
  zap trash: [
    "~/Library/Preferences/io.github.turman17.Domovy.plist",
    "~/Library/Saved Application State/io.github.turman17.Domovy.savedState",
  ]
end
