import Foundation

/// A short line of a matching message around the first match, for showing under a result.
/// Cut from the transcript when it is shown (the index keeps no text), with anything that
/// looks like a secret masked first. For display only: never log it.
public struct SearchSnippet: Hashable, Sendable {
    public let text: String
    /// Matches inside `text`.
    public let highlights: [Range<String.Index>]
    /// The message it was cut from, by index in the transcript.
    public let messageIndex: Int

    /// Characters shown before the first match and in all.
    static let lead = 60
    static let length = 180

    /// From the first message that matches every part of the query, starting at `preferring`
    /// (the index's first match); any message with a match when none matches every part.
    public static func make(from transcript: Transcript, query: SearchQuery, preferring index: Int? = nil) -> SearchSnippet? {
        guard !query.isEmpty else { return nil }
        let texts = transcript.messages.map(Self.text(of:))
        var order = Array(texts.indices)
        if let index, texts.indices.contains(index) { order = [index] + order.filter { $0 != index } }
        let pick = order.first { query.matchesAll(in: texts[$0]) } ?? order.first { !query.matches(in: texts[$0]).isEmpty }
        guard let pick else { return nil }
        return make(text: texts[pick], query: query, messageIndex: pick)
    }

    /// The text around the first match, on one line, masked.
    public static func make(text: String, query: SearchQuery, messageIndex: Int = 0) -> SearchSnippet? {
        let flat = TranscriptMask.TextMasker().mask(text)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard let first = query.matches(in: flat).first else { return nil }
        var start = flat.index(first.lowerBound, offsetBy: -lead, limitedBy: flat.startIndex) ?? flat.startIndex
        // Start on a word.
        if start > flat.startIndex, let space = flat[start..<first.lowerBound].firstIndex(of: " ") {
            start = flat.index(after: space)
        }
        var end = flat.index(start, offsetBy: length, limitedBy: flat.endIndex) ?? flat.endIndex
        if end < first.upperBound { end = first.upperBound }
        if end < flat.endIndex, let space = flat[first.upperBound..<end].lastIndex(of: " ") { end = space }
        let body = String(flat[start..<end])
        let prefix = start > flat.startIndex ? "\u{2026}" : ""
        let suffix = end < flat.endIndex ? "\u{2026}" : ""
        let snippet = prefix + body + suffix
        return SearchSnippet(text: snippet, highlights: query.matches(in: snippet), messageIndex: messageIndex)
    }

    static func text(of message: TranscriptMessage) -> String {
        message.blocks.map { block in
            switch block {
            case .text(let text): text
            case .toolCall(let summary): summary
            }
        }.joined(separator: "\n")
    }
}

/// Transcript search for the CLI and the MCP server: brings the index up to date with every
/// session at a home, then searches it.
public struct TranscriptSearcher: Sendable {
    public struct Result: Sendable {
        public let session: Session
        public let hit: TranscriptHit
    }

    public let context: DomovyContext

    public init(context: DomovyContext) {
        self.context = context
    }

    public func openIndex() throws -> TranscriptSearchIndex {
        try TranscriptSearchIndex(storeRoot: context.executor.storeRoot)
    }

    /// Every session of every installed agent.
    public func sessions() async throws -> [Session] {
        var sessions: [Session] = []
        for adapter in context.adapters where await adapter.status() != .notInstalled {
            sessions += try await adapter.sessions()
        }
        return sessions
    }

    /// Updates the index, then returns the best `limit` matches with their sessions.
    public func search(
        _ text: String,
        agent: AgentKind? = nil,
        limit: Int,
        index: TranscriptSearchIndex,
        progress: @Sendable (TranscriptSearchIndex.Progress) -> Void = { _ in }
    ) async throws -> [Result] {
        let sessions = try await sessions()
        _ = try await index.update(sessions: sessions, adapters: context.adapters, progress: progress)
        let byKey = Dictionary(sessions.map { (TranscriptSearchIndex.key($0.agent, $0.id), $0) }, uniquingKeysWith: { first, _ in first })
        return try await index.search(SearchQuery(text), agent: agent, limit: limit).compactMap { hit in
            byKey[TranscriptSearchIndex.key(hit.agent, hit.sessionID)].map { Result(session: $0, hit: hit) }
        }
    }

    /// The masked snippet of one result, read from its transcript.
    public func snippet(for result: Result, query: String) async -> SearchSnippet? {
        guard let adapter = context.adapters.first(where: { $0.kind == result.session.agent }),
              let transcript = try? await adapter.transcript(of: result.session, limit: result.hit.firstMessage + 1, masking: []) else { return nil }
        return SearchSnippet.make(from: transcript, query: SearchQuery(query), preferring: result.hit.firstMessage)
    }
}

extension TranscriptSearchIndex {
    /// Drops deleted sessions from the index at `storeRoot`, if there is one. Never creates it.
    public static func forget(_ sessions: [(agent: AgentKind, id: String)], storeRoot: URL) async {
        guard FileManager.default.fileExists(atPath: file(storeRoot: storeRoot).path),
              let index = try? TranscriptSearchIndex(storeRoot: storeRoot) else { return }
        try? await index.remove(sessions)
    }
}
