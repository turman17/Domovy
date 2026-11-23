import Foundation
import os

/// The `codex` executable and what it supports. Detected from `codex --help` (help text only;
/// Domovy never runs a Codex subcommand outside an executed plan).
public struct CodexCLI: Hashable, Codable, Sendable {
    public let executable: URL
    public let supportsDelete: Bool
    public let supportsArchive: Bool

    public init(executable: URL, supportsDelete: Bool, supportsArchive: Bool) {
        self.executable = executable
        self.supportsDelete = supportsDelete
        self.supportsArchive = supportsArchive
    }

    /// Which `codex` an adapter uses.
    public enum Choice: Hashable, Sendable {
        /// Look in `$PATH` and the usual install folders.
        case automatic
        /// Never run a Codex command; plans fall back to moving files.
        case none
        case executable(URL)
    }

    /// The choice for a home folder. A custom home (a fixture or `.devhome`) never gets the real
    /// CLI: it uses `<home>/bin/codex` if present (a stub), else none. `DOMOVY_CODEX_CLI`
    /// overrides both; set it to an empty string to disable the CLI.
    public static func choice(home: URL, isCustomHome: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> Choice {
        if let override = environment["DOMOVY_CODEX_CLI"] {
            return override.isEmpty ? .none : .executable(URL(fileURLWithPath: override))
        }
        guard isCustomHome else { return .automatic }
        let stub = home.appendingPathComponent("bin/codex")
        return FileManager.default.isExecutableFile(atPath: stub.path) ? .executable(stub) : .none
    }

    /// First executable `codex` in `$PATH` or the usual install folders.
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        ExternalTool.locate("codex", environment: environment)
    }

    /// Reads `codex --help` (with `CODEX_HOME` set to the adapter root) and looks for the
    /// `delete` and `archive` subcommands.
    static func probe(_ executable: URL, codexHome: URL) -> CodexCLI? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        guard let help = ExternalTool.output(executable, ["--help"], environment: ["CODEX_HOME": codexHome.path]), help.status == 0 else {
            Log.adapter.info("codex --help failed; using the file fallback")
            return nil
        }
        let commands = ExternalTool.subcommands(in: help.stdout)
        return CodexCLI(executable: executable, supportsDelete: commands.contains("delete"), supportsArchive: commands.contains("archive"))
    }
}

/// Resolves a `CodexCLI.Choice` once and remembers the answer for the adapter's lifetime.
final class CodexCLIResolver: Sendable {
    let choice: CodexCLI.Choice
    let codexHome: URL
    private let cached = OSAllocatedUnfairLock<CodexCLI??>(initialState: nil)

    init(choice: CodexCLI.Choice, codexHome: URL) {
        self.choice = choice
        self.codexHome = codexHome
    }

    func resolve() -> CodexCLI? {
        if let known = cached.withLock({ $0 }) { return known }
        let found: CodexCLI?
        switch choice {
        case .none: found = nil
        case .executable(let url): found = CodexCLI.probe(url, codexHome: codexHome)
        case .automatic: found = CodexCLI.locate().flatMap { CodexCLI.probe($0, codexHome: codexHome) }
        }
        cached.withLock { $0 = .some(found) }
        return found
    }
}
