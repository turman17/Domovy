import Foundation

/// Line-level helpers for `.jsonl` index files such as Claude Code's `history.jsonl`.
/// Lines are kept as raw bytes so that rewriting never changes the ones we keep.
enum JSONLines {
    struct Split: Sendable {
        var lines: [Data]
        /// Whether the file ended with a newline; preserved on rewrite.
        var trailingNewline: Bool

        func joined() -> Data {
            var out = Data()
            for (i, line) in lines.enumerated() {
                out.append(line)
                if i < lines.count - 1 || trailingNewline { out.append(UInt8(ascii: "\n")) }
            }
            return out
        }
    }

    static func split(_ data: Data) -> Split {
        guard !data.isEmpty else { return Split(lines: [], trailingNewline: false) }
        let trailing = data.last == UInt8(ascii: "\n")
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(Data.init)
        if trailing { lines.removeLast() }
        return Split(lines: lines, trailingNewline: trailing)
    }

    /// Zero-based indices of lines whose JSON object has `key` equal to `value`.
    static func indices(in lines: [Data], where key: String, equals value: String) -> [Int] {
        lines.indices.filter { index in
            guard let object = try? JSONSerialization.jsonObject(with: lines[index]) as? [String: Any] else { return false }
            return (object[key] as? String)?.lowercased() == value.lowercased()
        }
    }
}
