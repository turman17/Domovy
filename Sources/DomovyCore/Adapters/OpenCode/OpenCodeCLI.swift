import Foundation
import os

/// The `opencode` executable, when `opencode session --help` lists `delete` (verified on
/// 1.18.30, which prints its help to stderr). Domovy reads only the help here; `session delete`
/// runs only inside an executed plan.
public struct OpenCodeCLI: Hashable, Sendable {
    public let executable: URL

    /// OpenCode finds its data folder through `XDG_DATA_HOME` (assumed from its use of the XDG
    /// base directories; the default `~/.local/share` is verified).
    static func environment(dataFolder: URL) -> [String: String] {
        ["XDG_DATA_HOME": dataFolder.deletingLastPathComponent().path]
    }

    static func probe(_ executable: URL, dataFolder: URL) -> OpenCodeCLI? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        guard let help = ExternalTool.output(executable, ["session", "--help"], environment: environment(dataFolder: dataFolder),
                                             timeout: 20, mergingErrors: true),
              help.status == 0, help.stdout.contains("session delete") else {
            Log.adapter.info("opencode session --help does not list delete; OpenCode stays unchanged")
            return nil
        }
        return OpenCodeCLI(executable: executable)
    }

    /// A custom home (fixture, `.devhome`) only ever runs the stub at `<home>/bin/opencode`;
    /// `DOMOVY_OPENCODE_CLI` overrides, empty to disable.
    public static func choice(home: URL, isCustomHome: Bool) -> ToolChoice {
        ToolChoice.at(home: home, isCustomHome: isCustomHome, name: "opencode", override: "DOMOVY_OPENCODE_CLI")
    }
}

/// Resolves the choice once and remembers the answer for the adapter's lifetime.
final class OpenCodeCLIResolver: Sendable {
    let choice: ToolChoice
    let dataFolder: URL
    private let cached = OSAllocatedUnfairLock<OpenCodeCLI??>(initialState: nil)

    init(choice: ToolChoice, dataFolder: URL) {
        self.choice = choice
        self.dataFolder = dataFolder
    }

    func resolve() -> OpenCodeCLI? {
        if let known = cached.withLock({ $0 }) { return known }
        // The installer puts it in ~/.opencode/bin (verified), which is often not on $PATH.
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".opencode/bin").path
        let found = choice.resolve("opencode", extra: [installed]).flatMap { OpenCodeCLI.probe($0, dataFolder: dataFolder) }
        cached.withLock { $0 = .some(found) }
        return found
    }
}
