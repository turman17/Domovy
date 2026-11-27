import Foundation

/// A local full-text index of what was said in every session, for "find the chat where I
/// fixed the auth bug". SQLite FTS5 in Domovy's store folder.
///
/// It keeps as little as it can: the FTS table is contentless, so it holds word positions for
/// ranking and phrase matching but not the text; snippets are cut from the transcript itself
/// when a result is shown. Text is masked before it is indexed, so a secret's value is not a
/// searchable word. Each session is indexed again only when its transcript path, size or
/// modification time changed, and sessions that are gone are dropped from it.
/// Never log what is indexed or searched for.
public actor TranscriptSearchIndex {
    /// Bumped when the schema or what is indexed changes; an older index is built again.
    static let formatVersion: Int32 = 1
    /// Messages per session, characters per message and per session that are indexed.
    static let maxMessages = 5_000
    static let maxMessageCharacters = 64_000
    static let maxSessionCharacters = 4_000_000
    /// A batch is written once it holds this much text or this many sessions.
    static let batchCharacters = 8_000_000
    static let batchSessions = 40
    /// Transcripts read at the same time.
    static let readConcurrency = 4
    /// Low bits of an FTS rowid hold the message's index in its session.
    static let ordinalBits: Int64 = 20

    private let database: SearchDatabase
    public nonisolated let file: URL

    /// `<store>/Search/transcripts.sqlite`.
    public static func file(storeRoot: URL) -> URL {
        storeRoot.appendingPathComponent("Search", isDirectory: true).appendingPathComponent("transcripts.sqlite")
    }

    public init(storeRoot: URL) throws {
        file = Self.file(storeRoot: storeRoot)
        database = try SearchDatabase(file: file)
        try Self.prepare(database)
    }

    private static func prepare(_ database: SearchDatabase) throws {
        try database.exec("PRAGMA journal_mode = WAL")
        // Deleted sessions leave no words behind in free pages.
        try database.exec("PRAGMA secure_delete = ON")
        let version = try database.rows("PRAGMA user_version").first?.first?.integer ?? 0
        if version != Int64(formatVersion) {
            try database.exec("DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS docs")
        }
        do {
            try database.exec("""
            CREATE TABLE IF NOT EXISTS docs (
                id INTEGER PRIMARY KEY,
                agent TEXT NOT NULL,
                session_id TEXT NOT NULL,
                fingerprint TEXT NOT NULL,
                message_count INTEGER NOT NULL,
                UNIQUE (agent, session_id)
            );
            CREATE VIRTUAL TABLE IF NOT EXISTS messages USING fts5(
                body, content = '', contentless_delete = 1,
                tokenize = 'porter unicode61 remove_diacritics 2', prefix = '2 3'
            );
            PRAGMA user_version = \(formatVersion);
            """)
        } catch {
            throw SearchDatabase.Failure(reason: "Transcript search needs a newer SQLite than this Mac has (\(error.localizedDescription))")
        }
    }

    // MARK: Updating

    public struct Progress: Hashable, Sendable {
        /// Sessions looked at so far, of `total`.
        public let done: Int
        public let total: Int
        /// Sessions read and indexed so far (the others had not changed).
        public let indexed: Int
    }

    public struct Summary: Hashable, Sendable {
        public var total = 0
        public var indexed = 0
        public var unchanged = 0
        public var removed = 0
        /// Sessions whose transcript could not be read; tried again once they change.
        public var unreadable = 0
        public var cancelled = false
    }

    /// Brings the index in line with `sessions`: reads and indexes what changed, drops sessions
    /// not in the list. `read` returns the session's transcript; it is called for a few
    /// sessions at a time (`readConcurrency`), so memory holds those transcripts plus one batch
    /// of capped text. Stops between reads when the task is cancelled, keeping what was written.
    public func update(
        sessions: [Session],
        read: @escaping @Sendable (Session) async throws -> Transcript,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Summary {
        var unique: [String: Session] = [:]
        for session in sessions { unique[Self.key(session.agent, session.id)] = session }
        var summary = Summary(total: unique.count)
        var known: [String: (id: Int64, fingerprint: String)] = [:]
        for row in try database.rows("SELECT id, agent, session_id, fingerprint FROM docs") {
            known[Self.key(row[1].text ?? "", row[2].text ?? "")] = (row[0].integer, row[3].text ?? "")
        }
        let gone = known.filter { unique[$0.key] == nil }.map(\.value.id)
        if !gone.isEmpty {
            try transaction { for id in gone { try deleteDoc(id) } }
            summary.removed = gone.count
        }

        let ordered = unique.values.sorted { $0.lastActive > $1.lastActive }
        var changed: [Pending] = []
        for session in ordered {
            let key = Self.key(session.agent, session.id)
            let fingerprint = Self.fingerprint(session)
            if known[key]?.fingerprint == fingerprint {
                summary.unchanged += 1
            } else {
                changed.append(Pending(session: session, fingerprint: fingerprint, replacing: known[key]?.id, texts: []))
            }
        }
        var pending: [Pending] = []
        var pendingCharacters = 0
        var done = summary.unchanged
        progress(Progress(done: done, total: ordered.count, indexed: 0))
        for start in stride(from: 0, to: changed.count, by: Self.readConcurrency) {
            if Task.isCancelled {
                summary.cancelled = true
                break
            }
            // A few transcripts are read and masked at once, off the actor.
            let chunk = Array(changed[start..<min(start + Self.readConcurrency, changed.count)])
            let results = await withTaskGroup(of: (Int, [String]?).self) { group in
                for (offset, entry) in chunk.enumerated() {
                    group.addTask { (offset, (try? await read(entry.session)).map(Self.texts(of:))) }
                }
                var texts = [[String]?](repeating: nil, count: chunk.count)
                for await (offset, result) in group { texts[offset] = result }
                return texts
            }
            for (entry, texts) in zip(chunk, results) {
                var entry = entry
                if let texts { entry.texts = texts } else { summary.unreadable += 1 }
                summary.indexed += 1
                pendingCharacters += entry.texts.reduce(0) { $0 + $1.count }
                pending.append(entry)
            }
            done += chunk.count
            if pendingCharacters >= Self.batchCharacters || pending.count >= Self.batchSessions {
                try write(pending)
                pending = []
                pendingCharacters = 0
                progress(Progress(done: done, total: ordered.count, indexed: summary.indexed))
            }
        }
        try write(pending)
        progress(Progress(done: ordered.count, total: ordered.count, indexed: summary.indexed))
        return summary
    }

    /// Reads with each session's own adapter.
    public func update(
        sessions: [Session],
        adapters: [any AgentAdapter],
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Summary {
        let byKind = Dictionary(adapters.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        return try await update(sessions: sessions.filter { byKind[$0.agent] != nil }, read: { session in
            guard let adapter = byKind[session.agent] else { return .empty }
            return try await adapter.transcript(of: session, limit: TranscriptSearchIndex.maxMessages, masking: [])
        }, progress: progress)
    }

    /// Drops these sessions from the index (after they were deleted).
    public func remove(_ sessions: [(agent: AgentKind, id: String)]) throws {
        try transaction {
            for session in sessions {
                for row in try database.rows("SELECT id FROM docs WHERE agent = ?1 AND session_id = ?2", [.text(session.agent.rawValue), .text(session.id)]) {
                    try deleteDoc(row[0].integer)
                }
            }
        }
    }

    /// Empties the index; the next update reads every session again.
    public func removeAll() throws {
        try database.exec("DROP TABLE IF EXISTS messages; DROP TABLE IF EXISTS docs; PRAGMA user_version = 0")
        try database.exec("VACUUM")
        try Self.prepare(database)
    }

    /// Sessions in the index.
    public func count() throws -> Int {
        Int(try database.rows("SELECT count(*) FROM docs").first?.first?.integer ?? 0)
    }

    // MARK: Searching

    /// Sessions that match every part of `query`, each part in any of their messages, best
    /// first: FTS5's BM25 summed over the matching messages, so a session that talks about it
    /// more ranks higher. The first match is the first message that has every part, or else
    /// the first that has any.
    public func search(_ query: SearchQuery, agent: AgentKind? = nil, limit: Int = 500) throws -> [TranscriptHit] {
        let parts = Array(query.parts.prefix(SearchQuery.maxParts))
        guard !parts.isEmpty else { return [] }
        let bits = Self.ordinalBits
        let mask = (Int64(1) << bits) - 1
        var values: [SearchDatabase.Value] = parts.map { .text($0.ftsExpression) }
        values.append(.text(parts.map(\.ftsExpression).joined(separator: " AND ")))
        let all = values.count
        var ctes = parts.indices.map { i in
            "p\(i) AS MATERIALIZED (SELECT rowid AS r, bm25(messages) AS s FROM messages WHERE messages MATCH ?\(i + 1))"
        }
        ctes += parts.indices.map { i in "d\(i) AS (SELECT r >> \(bits) AS doc, sum(s) AS s FROM p\(i) GROUP BY 1)" }
        ctes.append("u AS (\(parts.indices.map { "SELECT r FROM p\($0)" }.joined(separator: " UNION ")))")
        ctes.append("c AS (SELECT r >> \(bits) AS doc, count(*) AS n, min(r & \(mask)) AS o FROM u GROUP BY 1)")
        ctes.append("a AS MATERIALIZED (SELECT rowid >> \(bits) AS doc, min(rowid & \(mask)) AS o FROM messages WHERE messages MATCH ?\(all) GROUP BY 1)")
        let joins = parts.indices.dropFirst().map { " JOIN d\($0) ON d\($0).doc = d0.doc" }.joined()
        let score = parts.indices.map { "d\($0).s" }.joined(separator: " + ")
        var sql = """
        WITH \(ctes.joined(separator: ",\n"))
        SELECT docs.agent, docs.session_id, c.n, \(score) AS score, coalesce(a.o, c.o)
        FROM d0\(joins) JOIN docs ON docs.id = d0.doc JOIN c ON c.doc = d0.doc LEFT JOIN a ON a.doc = d0.doc
        """
        if let agent {
            values.append(.text(agent.rawValue))
            sql += " WHERE docs.agent = ?\(values.count)"
        }
        sql += " ORDER BY score LIMIT \(max(1, limit))"
        return try database.rows(sql, values).compactMap { row in
            guard let agent = row[0].text.flatMap(AgentKind.init(rawValue:)), let id = row[1].text else { return nil }
            return TranscriptHit(agent: agent, sessionID: id, matchCount: Int(row[2].integer), score: -row[3].real, firstMessage: Int(row[4].integer))
        }
    }

    // MARK: Internals

    private struct Pending {
        let session: Session
        let fingerprint: String
        let replacing: Int64?
        var texts: [String]
    }

    private func write(_ pending: [Pending]) throws {
        guard !pending.isEmpty else { return }
        try transaction {
            let insert = try database.statement("INSERT INTO messages (rowid, body) VALUES (?1, ?2)")
            for entry in pending {
                if let old = entry.replacing { try deleteDoc(old) }
                try database.run("INSERT INTO docs (agent, session_id, fingerprint, message_count) VALUES (?1, ?2, ?3, ?4)", [
                    .text(entry.session.agent.rawValue), .text(entry.session.id), .text(entry.fingerprint), .integer(Int64(entry.texts.count)),
                ])
                let doc = database.lastInsertRowID
                for (ordinal, text) in entry.texts.enumerated() where !text.isEmpty {
                    try insert.run([.integer(doc << Self.ordinalBits | Int64(ordinal)), .text(text)])
                }
            }
        }
    }

    private func deleteDoc(_ id: Int64) throws {
        try database.run("DELETE FROM messages WHERE rowid >= ?1 AND rowid < ?2", [.integer(id << Self.ordinalBits), .integer((id + 1) << Self.ordinalBits)])
        try database.run("DELETE FROM docs WHERE id = ?1", [.integer(id)])
    }

    private func transaction(_ body: () throws -> Void) throws {
        try database.exec("BEGIN IMMEDIATE")
        do {
            try body()
            try database.exec("COMMIT")
        } catch {
            try? database.exec("ROLLBACK")
            throw error
        }
    }

    static func key(_ agent: AgentKind, _ id: String) -> String { key(agent.rawValue, id) }
    static func key(_ agent: String, _ id: String) -> String { agent + "\u{1F}" + id }

    /// What says a session changed: its transcript's path, size and modification time.
    static func fingerprint(_ session: Session) -> String {
        "\(session.transcriptURL.standardizedFileURL.path)|\(session.sizeBytes)|\(session.lastActive.timeIntervalSince1970)|\(session.memberCount)"
    }

    /// One text per message, in order (empty for a message with nothing to index), masked
    /// and cut to the limits. Tool calls count: "Edit src/auth.swift" is worth finding.
    static func texts(of transcript: Transcript) -> [String] {
        let masker = TranscriptMask.TextMasker()
        var budget = maxSessionCharacters
        var result: [String] = []
        for message in transcript.messages.prefix(maxMessages) {
            guard budget > 0 else { break }
            var text = message.blocks.map { block in
                switch block {
                case .text(let text): text
                case .toolCall(let summary): summary
                }
            }.joined(separator: "\n")
            if text.count > maxMessageCharacters { text = String(text.prefix(maxMessageCharacters)) }
            text = masker.mask(text)
            budget -= text.count
            result.append(text)
        }
        return result
    }
}

/// One session that matches a transcript search. Counts and positions only, never text.
public struct TranscriptHit: Hashable, Sendable {
    public let agent: AgentKind
    public let sessionID: String
    /// Messages of the session that match.
    public let matchCount: Int
    /// Higher is more relevant.
    public let score: Double
    /// Index of the first matching message in the session's transcript.
    public let firstMessage: Int

    public init(agent: AgentKind, sessionID: String, matchCount: Int, score: Double, firstMessage: Int) {
        self.agent = agent
        self.sessionID = sessionID
        self.matchCount = matchCount
        self.score = score
        self.firstMessage = firstMessage
    }
}
