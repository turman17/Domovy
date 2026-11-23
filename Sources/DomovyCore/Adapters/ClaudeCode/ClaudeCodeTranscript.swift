import Foundation

/// Reads the little we need from a transcript: the working directory and a title.
/// Transcripts may hold secrets, so this reads a bounded prefix, keeps only a short
/// title, and never logs content.
struct ClaudeCodeTranscript: Sendable {
    struct Header: Sendable {
        var cwd: String?
        var title: String?
    }

    /// How much of the file we are willing to read to find a title.
    static let maxBytes = 512 * 1024
    static let maxTitleLength = 120

    static func readHeader(of url: URL) -> Header {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Header() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), !data.isEmpty else { return Header() }

        var header = Header()
        var customTitle: String?
        for line in JSONLines.nonEmptyLines(data) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if header.cwd == nil, let cwd = object["cwd"] as? String, !cwd.isEmpty {
                header.cwd = cwd
            }
            if let type = object["type"] as? String {
                switch type {
                case "custom-title":
                    if let title = object["customTitle"] as? String { customTitle = clean(title) }
                case "user":
                    if header.title == nil, let prompt = userPrompt(in: object) { header.title = prompt }
                default:
                    break
                }
            }
            // A custom title wins, so once we have one and the cwd there is nothing left to learn.
            if customTitle != nil, header.cwd != nil { break }
        }
        if let customTitle { header.title = customTitle }
        return header
    }

    /// The first real prompt the user typed. Skips meta records, tool results and slash-command echoes.
    private static func userPrompt(in object: [String: Any]) -> String? {
        if object["isMeta"] as? Bool == true { return nil }
        guard let message = object["message"] as? [String: Any] else { return nil }
        var text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        }
        guard let text, let cleaned = clean(text), !looksLikeCommandEcho(cleaned) else { return nil }
        return cleaned
    }

    private static func looksLikeCommandEcho(_ text: String) -> Bool {
        text.hasPrefix("<command-") || text.hasPrefix("<local-command") || text.hasPrefix("<bash-") || text.hasPrefix("<system-reminder")
    }

    private static func clean(_ text: String) -> String? {
        let firstLine = text.split(maxSplits: 1, whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > maxTitleLength {
            return String(trimmed.prefix(maxTitleLength - 1)) + "\u{2026}"
        }
        return trimmed
    }
}
