import Foundation

/// Writes conversations as Markdown for "Export Transcript…" (the app) and tests. Anything that
/// looks like a secret is masked by default, line by line, with the same rules as the secret
/// scan; only an explicit choice exports the text as it is.
public enum TranscriptExport {
    /// The most messages one export reads per session.
    public static let messageLimit = 100_000

    public struct Item: Sendable {
        public let session: Session
        public let transcript: Transcript
        public let usage: TokenUsage?

        public init(session: Session, transcript: Transcript, usage: TokenUsage? = nil) {
            self.session = session
            self.transcript = transcript
            self.usage = usage
        }
    }

    public struct Output: Sendable {
        public let markdown: String
        /// Values replaced by their masked previews.
        public let maskedCount: Int
    }

    /// Reads each session's conversation through its adapter (zstd and databases included).
    /// `findings` of an earlier scan are masked before parsing when `masksSecrets` is on.
    public static func items(for sessions: [Session], adapters: [any AgentAdapter], masksSecrets: Bool,
                             findings: [Session.ID: [SecretFinding]] = [:], usage: [Session.ID: TokenUsageResult] = [:]) async throws -> [Item] {
        var items: [Item] = []
        for session in sessions {
            guard let adapter = adapters.first(where: { $0.kind == session.agent }) else { throw AdapterError.notInstalled(session.agent) }
            let transcript = try await adapter.transcript(of: session, limit: messageLimit, masking: masksSecrets ? findings[session.id] ?? [] : [])
            items.append(Item(session: session, transcript: transcript, usage: usage[session.id]?.usage))
        }
        return items
    }

    /// One Markdown document for every item, in order.
    public static func markdown(_ items: [Item], masksSecrets: Bool, exportedAt: Date = Date()) -> Output {
        var parts: [String] = []
        if items.count > 1 {
            parts.append("# \(items.count) agent sessions\n\nExported by Domovy on \(stamp(exportedAt)).")
        }
        for item in items { parts.append(section(item, headingLevel: items.count > 1 ? 2 : 1, exportedAt: items.count > 1 ? nil : exportedAt)) }
        let text = parts.joined(separator: "\n\n---\n\n") + "\n"
        guard masksSecrets else { return Output(markdown: text, maskedCount: 0) }
        let (masked, count) = mask(text)
        return Output(markdown: masked, maskedCount: count)
    }

    /// `text` with every value the secret rules match replaced by `[preview]`.
    public static func mask(_ text: String) -> (text: String, count: Int) {
        let matcher = SecretMatcher()
        var count = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let data = Data(line.utf8)
            let matches = matcher.matches(in: data).sorted { $0.range.lowerBound < $1.range.lowerBound }
            guard !matches.isEmpty else { return String(line) }
            var bytes = [UInt8](data)
            var end = Int.max
            for match in matches.reversed() where match.range.upperBound <= end {
                bytes.replaceSubrange(match.range, with: Array("[\(match.preview)]".utf8))
                end = match.range.lowerBound
                count += 1
            }
            return String(decoding: bytes, as: UTF8.self)
        }
        return (lines.joined(separator: "\n"), count)
    }

    /// "Fix the login bug.md": the title, without characters a file name cannot hold.
    public static func fileName(for sessions: [Session], extension ext: String) -> String {
        let base: String
        if sessions.count == 1, let session = sessions.first {
            base = session.displayTitle
        } else {
            base = "\(sessions.count) agent sessions"
        }
        var name = base.map { "/:\\\n\r\t".contains($0) ? "-" : $0 }.reduce(into: "") { $0.append($1) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.count > 80 { name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return (name.isEmpty ? "Transcript" : name) + "." + ext
    }

    /// Whether `url` is inside a folder an adapter owns. Exports never go there: the agent
    /// could read the file as one of its own.
    public static func isInsideAgentFolder(_ url: URL, adapters: [any AgentAdapter]) -> Bool {
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        return adapters.flatMap(\.scope).contains { folder in
            let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
            return target == base || target.hasPrefix(base.hasSuffix("/") ? base : base + "/")
        }
    }

    // MARK: Pieces

    private static func section(_ item: Item, headingLevel: Int, exportedAt: Date?) -> String {
        let session = item.session
        let hashes = String(repeating: "#", count: headingLevel)
        var lines = ["\(hashes) \(session.displayTitle.replacingOccurrences(of: "\n", with: " "))", ""]
        lines.append("- Agent: \(session.agentLabel)")
        if let project = session.projectPath { lines.append("- Project: `\(project)`") }
        lines.append("- Session: `\(session.id)`")
        lines.append("- Last active: \(stamp(session.lastActive))")
        if let usage = item.usage {
            let totals = usage.totals
            var line = "- Tokens: \(totals.total.formatted()) (input \(totals.input.formatted()), output \(totals.output.formatted()), cache read \(totals.cacheRead.formatted()), cache write \(totals.cacheWrite.formatted()))"
            if let cost = usage.cost { line += ", \(cost.text) \(cost.source == .agent ? "as recorded" : "estimated")" }
            lines.append(line)
        }
        if let exportedAt { lines.append("- Exported by Domovy on \(stamp(exportedAt))") }
        let messages = item.transcript.messages
        if messages.isEmpty {
            lines += ["", "_No messages Domovy can show._"]
        }
        for message in messages {
            let who = message.role == .user ? "You" : "Assistant"
            let when = message.timestamp.map { " \u{00B7} \(stamp($0))" } ?? ""
            lines += ["", "\(hashes)# \(who)\(when)", ""]
            for block in message.blocks {
                switch block {
                case .text(let text): lines.append(text)
                case .toolCall(let summary): lines.append("> Tool: \(summary)")
                }
                lines.append("")
            }
            if lines.last == "" { lines.removeLast() }
        }
        if item.transcript.isTruncated {
            lines += ["", "_The conversation is longer than Domovy reads at once; this export ends here._"]
        }
        if item.transcript.hiddenLineCount > 0 {
            let n = item.transcript.hiddenLineCount
            lines += ["", "_\(n) \(n == 1 ? "line was" : "lines were") left out: \(n == 1 ? "it holds" : "they hold") a possible secret Domovy could not mask._"]
        }
        return lines.joined(separator: "\n")
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}
