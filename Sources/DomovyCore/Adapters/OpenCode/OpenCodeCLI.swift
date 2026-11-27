import Foundation
import os

/// The `opencode` executable, when `opencode session --help` lists `delete` (verified on
/// 1.18.30, which prints its help to stderr). Domovy reads only the help here; `session delete`
/// runs only inside an executed plan.
public struct OpenCodeCLI: Hashable, Sendable {
    public let executable: URL

    /// OpenCode finds its data folder through `XDG_DATA_HOME` (assumed from its use of the XDG
    /// base directories; the default `~/.local/share` is verified).
    static func environment(dataFolder: URL, flavor: OpenCodeFlavor = .openCode) -> [String: String] {
        flavor.environment(dataFolder: dataFolder)
    }

    static func probe(_ executable: URL, dataFolder: URL, flavor: OpenCodeFlavor = .openCode) -> OpenCodeCLI? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        guard let help = ExternalTool.output(executable, ["session", "--help"], environment: flavor.environment(dataFolder: dataFolder),
                                             timeout: 20, mergingErrors: true),
              help.status == 0, help.stdout.contains("session delete") else {
            Log.adapter.info("\(flavor.executable, privacy: .public) session --help does not list delete; it stays unchanged")
            return nil
        }
        return OpenCodeCLI(executable: executable)
    }

    /// A custom home (fixture, `.devhome`) only ever runs the stub at `<home>/bin/opencode`;
    /// `DOMOVY_OPENCODE_CLI` overrides, empty to disable.
    public static func choice(home: URL, isCustomHome: Bool, flavor: OpenCodeFlavor = .openCode) -> ToolChoice {
        ToolChoice.at(home: home, isCustomHome: isCustomHome, name: flavor.executable, override: flavor.cliOverride)
    }
}

/// Resolves the choice once and remembers the answer for the adapter's lifetime.
final class OpenCodeCLIResolver: Sendable {
    let choice: ToolChoice
    let dataFolder: URL
    let flavor: OpenCodeFlavor
    private let cached = OSAllocatedUnfairLock<OpenCodeCLI??>(initialState: nil)

    init(choice: ToolChoice, dataFolder: URL, flavor: OpenCodeFlavor = .openCode) {
        self.choice = choice
        self.dataFolder = dataFolder
        self.flavor = flavor
    }

    func resolve() -> OpenCodeCLI? {
        if let known = cached.withLock({ $0 }) { return known }
        // The installer puts it in ~/.opencode/bin (verified), which is often not on $PATH.
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(flavor.installedBin).path
        let found = choice.resolve(flavor.executable, extra: [installed]).flatMap { OpenCodeCLI.probe($0, dataFolder: dataFolder, flavor: flavor) }
        cached.withLock { $0 = .some(found) }
        return found
    }
}
