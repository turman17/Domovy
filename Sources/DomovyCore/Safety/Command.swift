import Foundation

/// An agent's own command that a plan runs instead of editing its files (CLAUDE.md safety
/// rule 3), e.g. `codex delete --force <uuid>`. The result is verified afterwards.
public struct PlannedCommand: Hashable, Codable, Sendable {
    public let executable: URL
    public let arguments: [String]
    /// Added to the inherited environment (e.g. `CODEX_HOME` pointing at the adapter root).
    public let environment: [String: String]
    /// One line for the user: "Runs codex delete for this session, then checks the result."
    public let note: String
    /// Files the command removes for good. Domovy keeps a copy in its quarantine first, so undo
    /// can put them back (safety rule 1).
    public let copiesBeforeRun: [URL]
    /// Index lines the command removes. Domovy records them first, so undo can reinsert them.
    public let indexLinesBeforeRun: [IndexEdit]
    /// Checked after the command; whatever is still there is reported as a leftover.
    public let verifications: [Verification]
    /// Logical bytes the command removes or moves.
    public let sizeBytes: Int64
    /// What undo runs to reverse this command (e.g. `codex unarchive <uuid>`).
    public let undo: [PlannedCommand]
    /// The tool deletes for good and Domovy keeps no copy (`ollama rm`, `hf cache rm`): the
    /// undo entry is marked irreversible, and the sheet says so before it runs.
    public let isPermanent: Bool

    public init(
        executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        note: String,
        copiesBeforeRun: [URL] = [],
        indexLinesBeforeRun: [IndexEdit] = [],
        verifications: [Verification] = [],
        sizeBytes: Int64 = 0,
        undo: [PlannedCommand] = [],
        isPermanent: Bool = false
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.note = note
        self.copiesBeforeRun = copiesBeforeRun
        self.indexLinesBeforeRun = indexLinesBeforeRun
        self.verifications = verifications
        self.sizeBytes = sizeBytes
        self.undo = undo
        self.isPermanent = isPermanent
    }

    /// `codex delete --force 01a1...`, for display.
    public var commandLine: String {
        ([executable.lastPathComponent] + arguments).joined(separator: " ")
    }
}

extension PlannedCommand {
    private enum CodingKeys: String, CodingKey {
        case executable, arguments, environment, note, copiesBeforeRun, indexLinesBeforeRun, verifications, sizeBytes, undo, isPermanent
    }

    /// Undo entries written before `isPermanent` existed decode as reversible.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            executable: try c.decode(URL.self, forKey: .executable),
            arguments: try c.decode([String].self, forKey: .arguments),
            environment: try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:],
            note: try c.decode(String.self, forKey: .note),
            copiesBeforeRun: try c.decodeIfPresent([URL].self, forKey: .copiesBeforeRun) ?? [],
            indexLinesBeforeRun: try c.decodeIfPresent([IndexEdit].self, forKey: .indexLinesBeforeRun) ?? [],
            verifications: try c.decodeIfPresent([Verification].self, forKey: .verifications) ?? [],
            sizeBytes: try c.decodeIfPresent(Int64.self, forKey: .sizeBytes) ?? 0,
            undo: try c.decodeIfPresent([PlannedCommand].self, forKey: .undo) ?? [],
            isPermanent: try c.decodeIfPresent(Bool.self, forKey: .isPermanent) ?? false
        )
    }
}

/// One fact that must hold after a command ran.
public enum Verification: Hashable, Codable, Sendable {
    case fileGone(URL)
    case linesGone(file: URL, key: String, value: String)
    case rowsGone(database: URL, table: String, column: String, value: String)
    case fileAppears(directory: URL, nameContaining: String)
    /// Several files that should be gone, reported as one line: "2 of 3 layers of qwen3:14b
    /// (9.3 GB) are still in blobs/."
    case filesGone([URL], what: String)

    /// The files this check expects to be gone; they must not be open when the command runs.
    var urls: [URL] {
        switch self {
        case .fileGone(let url): [url]
        case .filesGone(let urls, _): urls
        case .linesGone, .rowsGone, .fileAppears: []
        }
    }

    /// `nil` when the check passes, otherwise a user-explainable leftover.
    func leftover() -> String? {
        switch self {
        case .fileGone(let url):
            return FileSystem.exists(url) ? "\(url.lastPathComponent) is still there." : nil
        case .linesGone(let file, let key, let value):
            guard let data = try? Data(contentsOf: file) else { return nil }
            let n = JSONLines.indices(in: JSONLines.split(data).lines, where: key, equals: value).count
            return n == 0 ? nil : "\(n) \(n == 1 ? "line stays" : "lines stay") in \(file.lastPathComponent)."
        case .rowsGone(let database, let table, let column, let value):
            guard let n = SQLiteReader(url: database)?.count(table: table, column: column, equals: value), n > 0 else { return nil }
            return "\(n) \(n == 1 ? "row stays" : "rows stay") in \(database.lastPathComponent) (\(table))."
        case .fileAppears(let directory, let fragment):
            let found = FileSystem.children(of: directory).contains { $0.lastPathComponent.contains(fragment) }
            return found ? nil : "Nothing for this session appeared in \(directory.lastPathComponent)/."
        case .filesGone(let urls, let what):
            let left = urls.filter { FileSystem.exists($0) }
            guard let first = left.first else { return nil }
            let bytes = CleanupPlan.bytes(DiskUsage.measure(left).allocated)
            let place = first.deletingLastPathComponent().lastPathComponent
            return "\(left.count) of \(urls.count) \(what) (\(bytes)) \(left.count == 1 ? "is" : "are") still in \(place)/."
        }
    }
}

public struct CommandResult: Hashable, Sendable {
    public let status: Int32
    /// The first part of stderr, for the error message. May name a session; never logged publicly.
    public let errorOutput: String

    public init(status: Int32, errorOutput: String) {
        self.status = status
        self.errorOutput = errorOutput
    }
}

/// Seam for running agent commands. Tests use `ProcessCommandRunner` with a stub executable.
public protocol CommandRunner: Sendable {
    func run(_ command: PlannedCommand) throws -> CommandResult
}

/// Runs the executable directly (no shell), stdin closed, with a timeout.
public struct ProcessCommandRunner: CommandRunner {
    public let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    public func run(_ command: PlannedCommand) throws -> CommandResult {
        try Self.run(command.executable, command.arguments, environment: command.environment, timeout: timeout)
    }

    /// Output goes to temporary files, so a chatty process can never block on a full pipe.
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: TimeInterval) throws -> CommandResult {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("domovy-run-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: scratch) }
        let out = scratch.appendingPathComponent("stdout")
        let err = scratch.appendingPathComponent("stderr")
        fm.createFile(atPath: out.path, contents: nil)
        fm.createFile(atPath: err.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outHandle
        process.standardError = errHandle
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return CommandResult(status: -1, errorOutput: "It did not finish within \(Int(timeout)) seconds and was stopped.")
        }
        let message = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
        return CommandResult(status: process.terminationStatus, errorOutput: String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)))
    }
}
