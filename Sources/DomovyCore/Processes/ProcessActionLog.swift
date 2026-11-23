import Foundation

/// One Freeze, Resume, Quit or Force Quit, as recorded next to the undo log. Names and pids
/// only, never command lines.
public struct ProcessActionRecord: Codable, Sendable, Identifiable {
    public var id: UUID = UUID()
    public let date: Date
    public let action: ProcessAction
    public let agent: AgentKind?
    public let rootName: String
    public let rootPID: Int32
    public let signaled: Int
    public let stillRunning: Int
    public let summary: String

    init(plan: ProcessActionPlan, result: ProcessActionResult, date: Date = Date()) {
        self.date = date
        action = plan.action
        agent = plan.agent
        rootName = plan.rootName
        rootPID = plan.targets.first?.pid ?? 0
        signaled = result.signaled.count
        stillRunning = result.stillRunning.count
        summary = result.summary
    }
}

/// `Undo/processes.jsonl` in Domovy's store: process actions, shown with the undo entries.
/// They are records only; Resume is how a freeze is reverted, and a quit cannot be.
public struct ProcessActionLog: Sendable {
    public let file: URL

    public init(storeRoot: URL) {
        file = storeRoot.appendingPathComponent("Undo", isDirectory: true).appendingPathComponent("processes.jsonl")
    }

    func append(_ record: ProcessActionRecord) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard var line = try? encoder.encode(record) else { return }
        line.append(0x0A)
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if !fm.fileExists(atPath: file.path) {
                fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            Log.processes.error("Could not record a process action: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Every record, oldest first. Lines that do not decode are skipped.
    public func records() -> [ProcessActionRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(ProcessActionRecord.self, from: Data($0)) }
    }
}
