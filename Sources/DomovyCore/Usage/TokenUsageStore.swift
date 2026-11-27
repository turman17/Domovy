import Foundation
import os

/// An adapter whose agent records token usage in its transcripts.
public protocol TokenUsageReporting: AgentAdapter {
    /// Files the usage is read from. Their paths, sizes and modification times key the cache.
    func usageSources(of session: Session) -> [URL]
    /// Reads the usage; `nil` when the session records none. Reads whole files: call it off
    /// the main actor.
    func readTokenUsage(of session: Session) throws -> TokenUsage?
}

/// What Domovy knows about a session's tokens.
public enum TokenUsageResult: Hashable, Sendable {
    case usage(TokenUsage)
    /// The agent records usage, but this session has none (no model reply yet).
    case notRecorded

    public var usage: TokenUsage? {
        if case .usage(let usage) = self { return usage }
        return nil
    }
}

/// Token usage per session, read lazily and cached in Domovy's folder by each source file's
/// path, size and modification time, so a rescan reads only transcripts that changed. The
/// cache holds counts and model ids only, never transcript text.
public final class TokenUsageStore: Sendable {
    struct FileStamp: Codable, Hashable, Sendable {
        let path: String
        let size: Int64
        let seconds: Int64
        let nanoseconds: Int64
    }

    struct Entry: Codable, Sendable {
        let stamps: [FileStamp]
        let usage: TokenUsage?
    }

    private struct State {
        var entries: [String: Entry]?
        var dirty = false
    }

    public let cacheFile: URL
    private let state = OSAllocatedUnfairLock(initialState: State())
    private static let logger = Logger(subsystem: "io.github.turman17.Domovy", category: "TokenUsage")
    private static let concurrency = 4

    public init(storeRoot: URL) {
        cacheFile = storeRoot.appendingPathComponent("token-usage-cache.json")
    }

    /// Whether this session's agent records tokens at all.
    public static func isSupported(_ session: Session, adapters: [any AgentAdapter]) -> Bool {
        adapters.contains { $0.kind == session.agent && $0 is any TokenUsageReporting }
    }

    /// Usage of each session whose agent records tokens; sessions of other agents are left
    /// out. `cachedOnly` answers from the cache without reading a transcript.
    public func usage(for sessions: [Session], adapters: [any AgentAdapter], cachedOnly: Bool = false) async -> [Session.ID: TokenUsageResult] {
        var reporters: [AgentKind: any TokenUsageReporting] = [:]
        for case let adapter as any TokenUsageReporting in adapters where reporters[adapter.kind] == nil {
            reporters[adapter.kind] = adapter
        }
        let work = sessions.compactMap { session in reporters[session.agent].map { (session, $0) } }
        guard !work.isEmpty else { return [:] }
        loadIfNeeded()
        var results: [Session.ID: TokenUsageResult] = [:]
        var pending: [(Session, any TokenUsageReporting, [FileStamp], String)] = []
        for (session, adapter) in work {
            let key = Self.key(session)
            let stamps = Self.stamps(adapter.usageSources(of: session))
            if let entry = state.withLock({ $0.entries?[key] }), entry.stamps == stamps {
                results[session.id] = entry.usage.map(TokenUsageResult.usage) ?? .notRecorded
            } else if !cachedOnly, !stamps.isEmpty {
                pending.append((session, adapter, stamps, key))
            }
        }
        if !pending.isEmpty {
            await withTaskGroup(of: (Session.ID, String, [FileStamp], TokenUsage??).self) { group in
                var next = 0
                func start() {
                    guard next < pending.count else { return }
                    let (session, adapter, stamps, key) = pending[next]
                    next += 1
                    group.addTask {
                        do {
                            return (session.id, key, stamps, .some(try adapter.readTokenUsage(of: session)))
                        } catch {
                            Self.logger.error("Reading token usage failed: \(error.localizedDescription, privacy: .private)")
                            return (session.id, key, stamps, .none)
                        }
                    }
                }
                for _ in 0..<Self.concurrency { start() }
                for await (id, key, stamps, read) in group {
                    start()
                    // A read that failed is not cached: it is tried again next time.
                    guard case .some(let found) = read else { continue }
                    let usage = found.flatMap { $0.isEmpty ? nil : $0 }
                    results[id] = usage.map(TokenUsageResult.usage) ?? .notRecorded
                    state.withLock {
                        $0.entries?[key] = Entry(stamps: stamps, usage: usage)
                        $0.dirty = true
                    }
                }
            }
            save()
        }
        return results
    }

    /// Writes the cache if it changed. Entries of sessions that are gone are dropped with
    /// `prune(keeping:)`.
    public func save() {
        let snapshot: [String: Entry]? = state.withLock { state in
            guard state.dirty else { return nil }
            state.dirty = false
            return state.entries
        }
        guard let snapshot else { return }
        do {
            try FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(to: cacheFile, options: .atomic)
        } catch {
            Self.logger.error("Saving the token cache failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Forgets sessions not in `sessions`.
    public func prune(keeping sessions: [Session]) {
        loadIfNeeded()
        let keep = Set(sessions.map(Self.key))
        state.withLock { state in
            let before = state.entries?.count ?? 0
            state.entries = state.entries?.filter { keep.contains($0.key) }
            if state.entries?.count != before { state.dirty = true }
        }
        save()
    }

    private func loadIfNeeded() {
        guard state.withLock({ $0.entries == nil }) else { return }
        let loaded = (try? Data(contentsOf: cacheFile)).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        state.withLock { if $0.entries == nil { $0.entries = loaded } }
    }

    static func key(_ session: Session) -> String {
        "\(session.agent.rawValue)/\(session.id)"
    }

    /// Stamps of the files that exist; empty when none does.
    static func stamps(_ files: [URL]) -> [FileStamp] {
        files.compactMap { file in
            var info = stat()
            guard stat(file.path, &info) == 0 else { return nil }
            return FileStamp(path: file.path, size: Int64(info.st_size),
                             seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
        }
    }
}

// MARK: Adapters

extension ClaudeCodeAdapter: TokenUsageReporting {
    /// The transcript and its subagents' transcripts (`<id>/subagents/*.jsonl`).
    public func usageSources(of session: Session) -> [URL] {
        let subagents = session.transcriptURL.deletingLastPathComponent()
            .appendingPathComponent(session.id, isDirectory: true).appendingPathComponent("subagents", isDirectory: true)
        let extra = FileSystem.children(of: subagents).filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        return [session.transcriptURL] + extra
    }

    public func readTokenUsage(of session: Session) throws -> TokenUsage? {
        try UsageParsers.claudeCode(usageSources(of: session))
    }
}

extension CodexAdapter: TokenUsageReporting {
    public func usageSources(of session: Session) -> [URL] { [session.transcriptURL] }

    public func readTokenUsage(of session: Session) throws -> TokenUsage? {
        try UsageParsers.codex(session.transcriptURL)
    }
}

extension GeminiAdapter: TokenUsageReporting {
    /// A grouped row stands for chats without messages: nothing to count.
    public func usageSources(of session: Session) -> [URL] {
        session.memberCount > 1 ? [] : [session.transcriptURL]
    }

    public func readTokenUsage(of session: Session) throws -> TokenUsage? {
        session.memberCount > 1 ? nil : try UsageParsers.gemini(session.transcriptURL)
    }
}

extension QwenAdapter: TokenUsageReporting {
    public func usageSources(of session: Session) -> [URL] { [session.transcriptURL] }

    public func readTokenUsage(of session: Session) throws -> TokenUsage? {
        try UsageParsers.qwen(session.transcriptURL)
    }
}

extension CopilotAdapter: TokenUsageReporting {
    public func usageSources(of session: Session) -> [URL] { [session.transcriptURL] }

    public func readTokenUsage(of session: Session) throws -> TokenUsage? {
        try UsageParsers.copilot(session.transcriptURL)
    }
}

extension ZedAdapter: TokenUsageReporting {
    /// Threads of Zed's own agent; external agents' sessions are counted by their own agent.
    public func usageSources(of session: Session) -> [URL] {
        session.transcriptURL.standardizedFileURL == layout.threadsDatabase.standardizedFileURL ? layout.threadsFiles : []
    }

    public func readTokenUsage(of session: Session) throws -> TokenUsage? {
        guard !usageSources(of: session).isEmpty else { return nil }
        return UsageParsers.zed(try ZedIndex.jsonData(of: session.id, in: layout))
    }
}

extension OpenCodeAdapter: TokenUsageReporting {
    /// The database with its WAL: OpenCode writes new messages there first.
    public func usageSources(of session: Session) -> [URL] {
        SharedDatabaseLiveness.files(of: layout.database)
    }

    public func readTokenUsage(of session: Session) throws -> TokenUsage? {
        UsageParsers.openCode(database: layout.database, sessionID: session.id)
    }
}
