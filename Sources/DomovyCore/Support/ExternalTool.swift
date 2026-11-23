import Foundation

/// Which executable of a tool's own CLI (`codex`, `ollama`, `hf`) a plan may run.
public enum ToolChoice: Hashable, Sendable {
    /// Look in `$PATH` and the usual install folders.
    case automatic
    /// Never run the tool; plans fall back to moving files.
    case none
    case executable(URL)

    /// The choice for a home folder. A custom home (a fixture or `.devhome`) never gets the real
    /// CLI: it uses `<home>/bin/<name>` if present (a stub), else none. `override` names an
    /// environment variable that wins over both; set it to an empty string to disable the CLI.
    public static func at(home: URL, isCustomHome: Bool, name: String, override: String,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> ToolChoice {
        if let value = environment[override] {
            return value.isEmpty ? .none : .executable(URL(fileURLWithPath: value))
        }
        guard isCustomHome else { return .automatic }
        let stub = home.appendingPathComponent("bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: stub.path) ? .executable(stub) : .none
    }

    /// The executable, if there is one. Locating reads directory entries only; nothing runs.
    func resolve(_ name: String, extra: [String] = []) -> URL? {
        switch self {
        case .none: nil
        case .executable(let url): FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
        case .automatic: ExternalTool.locate(name, extra: extra)
        }
    }
}

/// Finding and running a tool's read-only commands (`--help`, `ps`). Mutating commands only ever
/// run inside an executed plan, through `CommandRunner`.
enum ExternalTool {
    /// First executable `name` in `$PATH` or the usual install folders. Apps started from
    /// Finder get a minimal `$PATH`, so Homebrew and npm locations are checked explicitly.
    static func locate(_ name: String, extra: [String] = [], environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let usual = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        for directory in path + usual + extra {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Runs `executable` without a shell, stdin closed, and returns its exit status and stdout.
    /// `nil` when it could not start. Output goes to a temporary file, never a pipe that can fill.
    /// - Parameter mergingErrors: also capture stderr (OpenCode prints its help there).
    static func output(_ executable: URL, _ arguments: [String], environment: [String: String] = [:], timeout: TimeInterval = 10,
                       mergingErrors: Bool = false) -> (status: Int32, stdout: String)? {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("domovy-tool-\(UUID().uuidString)")
        guard fm.createFile(atPath: scratch.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let out = try? FileHandle(forWritingTo: scratch) else { return nil }
        defer {
            try? out.close()
            try? fm.removeItem(at: scratch)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = mergingErrors ? out : FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        return (process.terminationStatus, (try? String(contentsOf: scratch, encoding: .utf8)) ?? "")
    }

    /// Subcommand names in help text: lines indented by exactly two spaces, first word.
    static func subcommands(in help: String) -> Set<String> {
        Set(help.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  "), !line.hasPrefix("   ") else { return nil }
            return line.split(separator: " ").first.map(String.init)
        })
    }
}
