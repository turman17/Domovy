import Foundation

/// Adds and removes one `[a.b]` table of a TOML config (Codex `config.toml`) as whole lines.
/// Nothing outside the table's lines changes; a table appended and removed again gives back
/// the original file.
enum TOMLTableEditor {
    /// The line ranges (byte offsets) of `[<table>]` and its subtables, or `nil` when absent.
    static func range(of table: [String], in text: String) -> Range<String.Index>? {
        var start: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
            let line = text[index..<lineEnd]
            if let header = header(line) {
                if let begun = start {
                    if !header.starts(with: table) { return begun..<index }
                } else if header == table {
                    start = index
                }
            }
            index = lineEnd
        }
        return start.map { $0..<text.endIndex }
    }

    /// The table's key path when `line` is a `[table]` header (not `[[array]]`).
    static func header(_ line: Substring) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), !trimmed.hasPrefix("[["), let close = trimmed.lastIndex(of: "]") else { return nil }
        let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        return inner.split(separator: ".").map { part in
            var key = part.trimmingCharacters(in: .whitespaces)
            if key.count >= 2, let first = key.first, first == "\"" || first == "'", key.last == first {
                key = String(key.dropFirst().dropLast())
            }
            return key
        }
    }

    /// The value of a `key = "string"` line directly in the table.
    static func string(_ key: String, in block: Substring) -> String? {
        for line in block.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard let data = value.data(using: .utf8), let text = try? JSONDecoder().decode(String.self, from: data) else { return nil }
            return text
        }
        return nil
    }

    /// The table defined some other way: a dotted key or inline table naming it outside a
    /// `[table]` header. Domovy does not edit such files.
    static func hasOtherDefinition(of table: [String], in text: String) -> Bool {
        guard table.count == 2 else { return false }
        var current: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let header = header(line) { current = header; continue }
            let key = line.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: " ", with: "") ?? ""
            guard line.contains("=") else { continue }
            if current.isEmpty, key.hasPrefix("\(table[0]).\(table[1])") { return true }
            if current == [table[0]], key == table[1] || key.hasPrefix("\(table[1]).") { return true }
        }
        return false
    }

    /// The text to append to `text` for `block` (which ends with a newline): a blank line first
    /// unless the file is empty.
    static func appendix(for block: String, after text: String) -> String {
        if text.isEmpty { return block }
        return (text.hasSuffix("\n") ? "\n" : "\n\n") + block
    }

    /// `text` without the table. `appended` is what connect added; when the file still ends
    /// with it, exactly that goes. Otherwise the table's lines go, with one blank line before.
    static func removing(_ table: [String], from text: String, appended: String?) -> String? {
        if let appended, !appended.isEmpty, text.hasSuffix(appended) {
            return String(text.dropLast(appended.count))
        }
        guard let range = range(of: table, in: text) else { return nil }
        var lower = range.lowerBound
        // At the end of the file, the blank line that separated the table goes too; in the
        // middle, the table's own trailing blank line already keeps the spacing.
        if range.upperBound == text.endIndex, lower > text.startIndex, text[..<lower].hasSuffix("\n\n") { lower = text.index(before: lower) }
        var result = text
        result.removeSubrange(lower..<range.upperBound)
        return result
    }

    /// A TOML basic string.
    static func quote(_ text: String) -> String {
        String(decoding: JSONValue.string(text).encoded(), as: UTF8.self)
    }
}
