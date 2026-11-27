import Foundation

/// One session a run left alone, and why. Never the session's title: history stays free of
/// transcript text.
public struct RuleSkip: Codable, Hashable, Sendable {
    public let ruleID: UUID?
    public let agent: AgentKind
    /// `nil` for a note about a whole agent ("Antigravity is read-only").
    public let sessionID: String?
    public let reason: String

    public init(ruleID: UUID?, agent: AgentKind, sessionID: String?, reason: String) {
        self.ruleID = ruleID
        self.agent = agent
        self.sessionID = sessionID
        self.reason = reason
    }
}

/// One run of the rules, as the history shows it.
public struct RuleRunRecord: Identifiable, Codable, Hashable, Sendable {
    public enum Trigger: String, Codable, Sendable {
        /// The nightly run in the app, or `domo rules run --scheduled` from launchd.
        case scheduled
        /// "Run Now" or a reviewed plan in the app.
        case manual
        case cli
    }

    public enum Outcome: String, Codable, Sendable {
        case completed
        /// Some plans failed; what ran is undoable.
        case partial
        case nothingToDo
        /// Not run: on battery below 20 % or Low Power Mode.
        case skippedPower
        /// Ask-before-running rules matched sessions; a review is waiting.
        case awaitingReview
        case failed
    }

    public let id: UUID
    public let startedAt: Date
    public var finishedAt: Date
    public let trigger: Trigger
    public let ruleIDs: [UUID]
    public var outcome: Outcome
    public var archivedSessions: Int
    public var removedSessions: Int
    /// Where removed sessions went; `nil` when none were removed or they went to both places.
    public var removedTo: Destination?
    public var bytes: Int64
    /// The undo log batch every entry of this run shares; `nil` when nothing changed.
    public var undoGroupID: UUID?
    public var entryIDs: [UUID]
    public var skipped: [RuleSkip]
    public var notes: [String]
    /// Set when the run was undone from the history.
    public var undoneAt: Date?

    public init(
        id: UUID = UUID(), startedAt: Date, finishedAt: Date, trigger: Trigger, ruleIDs: [UUID], outcome: Outcome,
        archivedSessions: Int = 0, removedSessions: Int = 0, removedTo: Destination? = nil, bytes: Int64 = 0, undoGroupID: UUID? = nil,
        entryIDs: [UUID] = [], skipped: [RuleSkip] = [], notes: [String] = [], undoneAt: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.trigger = trigger
        self.ruleIDs = ruleIDs
        self.outcome = outcome
        self.archivedSessions = archivedSessions
        self.removedSessions = removedSessions
        self.removedTo = removedTo
        self.bytes = bytes
        self.undoGroupID = undoGroupID
        self.entryIDs = entryIDs
        self.skipped = skipped
        self.notes = notes
        self.undoneAt = undoneAt
    }

    public var changedAnything: Bool { !entryIDs.isEmpty }

    /// "Archived 12 sessions (340 MB)." in the Domovy voice.
    public var summary: String {
        switch outcome {
        case .skippedPower: return notes.first ?? "Skipped to save battery."
        case .awaitingReview: return notes.first ?? "Waiting for your review."
        case .nothingToDo where skipped.isEmpty: return "Nothing matched. The house is in order."
        case .nothingToDo: return "Nothing changed. \(skipped.count) \(skipped.count == 1 ? "session was" : "sessions were") left alone."
        case .failed: return notes.first ?? "The run stopped before changing anything."
        case .completed, .partial: break
        }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        var parts: [String] = []
        if archivedSessions > 0 { parts.append("archived \(Self.sessions(archivedSessions))") }
        if removedSessions > 0 { parts.append("moved \(Self.sessions(removedSessions)) to \(removedTo?.displayName ?? "the Trash and the quarantine folder")") }
        let text = parts.joined(separator: " and ")
        var line = text.prefix(1).uppercased() + text.dropFirst() + " (\(size))."
        if outcome == .partial { line += " Some sessions could not be changed." }
        return line
    }

    static func sessions(_ n: Int) -> String { "\(n) \(n == 1 ? "session" : "sessions")" }
}

/// Times the scheduler needs between launches.
public struct RuleScheduleState: Codable, Hashable, Sendable {
    /// When the scheduler first looked; the first nightly run is the one after it.
    public var anchor: Date?
    /// The last scheduled run (or skip).
    public var lastScheduledRun: Date?

    public init(anchor: Date? = nil, lastScheduledRun: Date? = nil) {
        self.anchor = anchor
        self.lastScheduledRun = lastScheduledRun
    }
}

/// Rules, run history and schedule state in Domovy's own folder (`<store>/Rules/`), shared by
/// the app and `domo`. Owner-only files, written atomically.
public struct RuleStore: Sendable {
    public let directory: URL
    /// Runs kept in the history; older ones drop off.
    public static let historyLimit = 100

    public init(storeRoot: URL) {
        directory = storeRoot.appendingPathComponent("Rules", isDirectory: true)
    }

    var rulesFile: URL { directory.appendingPathComponent("rules.json") }
    var historyFile: URL { directory.appendingPathComponent("history.json") }
    var stateFile: URL { directory.appendingPathComponent("schedule.json") }

    /// The saved rules; the presets (all off) until anything was saved.
    public func rules() throws -> [CleanupRule] {
        guard FileSystem.exists(rulesFile) else { return CleanupRule.presets }
        return try read([CleanupRule].self, from: rulesFile)
    }

    public func save(_ rules: [CleanupRule]) throws {
        try write(rules, to: rulesFile)
    }

    /// Adds or replaces a rule by id.
    public func upsert(_ rule: CleanupRule) throws {
        var all = try rules()
        if let index = all.firstIndex(where: { $0.id == rule.id }) { all[index] = rule } else { all.append(rule) }
        try save(all)
    }

    public func remove(_ id: UUID) throws {
        try save(try rules().filter { $0.id != id })
    }

    /// Newest first.
    public func history() throws -> [RuleRunRecord] {
        guard FileSystem.exists(historyFile) else { return [] }
        return try read([RuleRunRecord].self, from: historyFile)
    }

    public func record(_ run: RuleRunRecord) throws {
        var all = try history().filter { $0.id != run.id }
        all.insert(run, at: 0)
        try write(Array(all.prefix(Self.historyLimit)), to: historyFile)
    }

    public func scheduleState() -> RuleScheduleState {
        (try? read(RuleScheduleState.self, from: stateFile)) ?? RuleScheduleState()
    }

    public func save(_ state: RuleScheduleState) throws {
        try write(state, to: stateFile)
    }

    // MARK: Files

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            throw RuleError.unreadable(url.lastPathComponent, reason: error.localizedDescription)
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Errors of the rules, written for the user.
public enum RuleError: Error, LocalizedError, Hashable, Sendable {
    case unreadable(String, reason: String)
    case invalid(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let file, let reason): "Could not read the rules file \(file): \(reason)"
        case .invalid(let problem): problem
        case .notFound(let id): "No rule with id \(id)."
        }
    }
}
