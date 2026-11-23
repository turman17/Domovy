import Foundation
import os

/// The `gemini` executable, when its help lists `--delete-session`. Domovy reads only
/// `gemini --help` here; `--delete-session` runs only inside an executed plan.
public struct GeminiCLI: Hashable, Sendable {
    public let executable: URL

    /// Reads `gemini --help` and looks for `--delete-session`.
    static func probe(_ executable: URL) -> GeminiCLI? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        guard let help = ExternalTool.output(executable, ["--help"], timeout: 20), help.status == 0,
              help.stdout.contains("--delete-session") else {
            Log.adapter.info("gemini --help does not list --delete-session; using the file fallback")
            return nil
        }
        return GeminiCLI(executable: executable)
    }

    /// The choice for a home folder: a custom home (fixture, `.devhome`) only ever runs the stub
    /// at `<home>/bin/gemini`; `DOMOVY_GEMINI_CLI` overrides, empty to disable.
    public static func choice(home: URL, isCustomHome: Bool) -> ToolChoice {
        ToolChoice.at(home: home, isCustomHome: isCustomHome, name: "gemini", override: "DOMOVY_GEMINI_CLI")
    }
}

/// Resolves the choice once and remembers the answer for the adapter's lifetime.
final class GeminiCLIResolver: Sendable {
    let choice: ToolChoice
    private let cached = OSAllocatedUnfairLock<GeminiCLI??>(initialState: nil)

    init(choice: ToolChoice) {
        self.choice = choice
    }

    func resolve() -> GeminiCLI? {
        if let known = cached.withLock({ $0 }) { return known }
        let found = choice.resolve("gemini").flatMap(GeminiCLI.probe)
        cached.withLock { $0 = .some(found) }
        return found
    }
}
