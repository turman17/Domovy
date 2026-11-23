import Foundation

extension Session {
    /// The first prompt as plain text, for lists. Wrappers the agents put before the prompt
    /// (`<session_context>…</session_context>`, `<system-reminder>`, …), paste placeholders and
    /// markdown markers are removed. A prompt that was only such wrappers reads "Gemini CLI
    /// session, 21 Nov 2026"; one that was only pasted text reads "Pasted text".
    public var displayTitle: String {
        Self.cleanTitle(title) ?? "\(agent.displayName) session, \(lastActive.formatted(date: .abbreviated, time: .omitted))"
    }

    /// `nil` when nothing a person typed is left.
    static func cleanTitle(_ raw: String?) -> String? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        text = stripLeadingWrappers(text)
        var hadPaste = false
        if text.contains("<pasted_content") || text.contains("</pasted_content>") {
            hadPaste = true
            text = text.replacingOccurrences(of: #"</?pasted_content[^>]*>?"#, with: " ", options: .regularExpression)
        }
        if text.contains("**") || text.contains("`") || text.contains("__") {
            text = text.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return hadPaste ? "Pasted text" : nil }
        return text
    }

    /// Context blocks an agent adds before the prompt: dropped with what they hold.
    private static let contextTags: Set<String> = [
        "session_context", "system-reminder", "environment_context", "user_instructions",
        "local-command-stdout", "local-command-stderr", "local-command-caveat", "command-message",
    ]

    /// Removes wrapper tags at the start of the text. Context blocks go with their content; other
    /// wrappers (`<command-name>/review</command-name>`) keep what they hold. Tags later in the
    /// prompt are the person's own words and stay.
    static func stripLeadingWrappers(_ input: String) -> String {
        var text = Substring(input)
        while let open = text.firstMatch(of: /^\s*<([A-Za-z][\w-]*)(?:\s[^>]*)?>/) {
            let name = String(open.output.1)
            // Paste placeholders are handled below, wherever they are.
            if name == "pasted_content" { break }
            let closing = "</\(name)>"
            let rest = text[open.range.upperBound...]
            if contextTags.contains(name) {
                // Unclosed: the whole remainder is context.
                guard let close = rest.range(of: closing) else { return "" }
                text = rest[close.upperBound...]
            } else if let close = rest.range(of: closing) {
                text = Substring(String(rest[..<close.lowerBound]) + " " + String(rest[close.upperBound...]))
            } else {
                text = rest
            }
        }
        // A lone closing tag left at the start ("</command-name> …").
        if let stray = text.firstMatch(of: /^\s*<\/[A-Za-z][\w-]*>/) { text = text[stray.range.upperBound...] }
        // A slash command's arguments follow its name: "/review auth".
        let result = String(text)
            .replacing(/<\/?command-(?:name|args)>/, with: " ")
            .replacing(/\s+/, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
