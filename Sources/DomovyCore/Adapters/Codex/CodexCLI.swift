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

    /// First executable `codex` in `$PATH` or the usual install folders. Apps started from
    /// Finder get a minimal `$PATH`, so Homebrew and npm locations are checked explicitly.
    static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        for directory in path + extra {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Reads `codex --help` (with `CODEX_HOME` set to the adapter root) and looks for the
    /// `delete` and `archive` subcommands.
    static func probe(_ executable: URL, codexHome: URL) -> CodexCLI? {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-codex-help-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        guard let help = try? helpText(executable, codexHome: codexHome, scratch: scratch) else {
            Log.adapter.info("codex --help failed; using the file fallback")
            return nil
        }
        let commands = Set(help.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  "), !line.hasPrefix("   ") else { return nil }
            return line.split(separator: " ").first.map(String.init)
        })
        return CodexCLI(executable: executable, supportsDelete: commands.contains("delete"), supportsArchive: commands.contains("archive"))
    }

    private static func helpText(_ executable: URL, codexHome: URL, scratch: URL) throws -> String {
        let fm = FileManager.default
        fm.createFile(atPath: scratch.path, contents: nil)
        let out = try FileHandle(forWritingTo: scratch)
        defer { try? out.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--help"]
        process.environment = ProcessInfo.processInfo.environment.merging(["CODEX_HOME": codexHome.path]) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return (try? String(contentsOf: scratch, encoding: .utf8)) ?? ""
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
