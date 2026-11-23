import Foundation

/// Cuts entries out of a JSON list without re-serializing the rest: every byte outside the cut
/// entries (and one separating comma) stays exactly as it was, so keys, order, spacing and
/// number formats of the other entries are untouched.
enum JSONListCut {
    /// The list's entries: the top-level array, or the array under `field` of the top-level
    /// object. `nil` when the value has neither shape.
    static func entries(in data: Data, field: String?) -> [Range<Int>]? {
        let bytes = [UInt8](data)
        var scanner = Scanner(bytes: bytes)
        scanner.skipSpace()
        if let field {
            guard scanner.peek == UInt8(ascii: "{") else { return nil }
            scanner.index += 1
            while true {
                scanner.skipSpace()
                guard let keyEnd = scanner.skipString() else { return nil }
                let key = try? JSONSerialization.jsonObject(with: Data(bytes[scanner.index..<keyEnd]), options: .fragmentsAllowed) as? String
                scanner.index = keyEnd
                scanner.skipSpace()
                guard scanner.peek == UInt8(ascii: ":") else { return nil }
                scanner.index += 1
                scanner.skipSpace()
                if key == field {
                    return scanner.peek == UInt8(ascii: "[") ? scanner.arrayEntries() : nil
                }
                guard let end = scanner.skipValue() else { return nil }
                scanner.index = end
                scanner.skipSpace()
                guard scanner.peek == UInt8(ascii: ",") else { return nil }
                scanner.index += 1
            }
        }
        guard scanner.peek == UInt8(ascii: "[") else { return nil }
        return scanner.arrayEntries()
    }

    /// `data` without the entries whose `idField` is `id`, and how many went. `nil` when the
    /// list cannot be found or the result would not be valid JSON.
    static func removing(from data: Data, field: String?, idField: String, id: String) -> (data: Data, removed: Int)? {
        guard let entries = entries(in: data, field: field) else { return nil }
        let bytes = [UInt8](data)
        let matching = entries.indices.filter { index in
            let object = try? JSONSerialization.jsonObject(with: Data(bytes[entries[index]])) as? [String: Any]
            return object?[idField] as? String == id
        }
        guard !matching.isEmpty else { return (data, 0) }
        var result = bytes
        var remaining = entries
        // Last first, so earlier ranges stay valid.
        for index in matching.reversed() {
            let cut: Range<Int>
            if index > 0 {
                cut = remaining[index - 1].upperBound..<remaining[index].upperBound
            } else if remaining.count > 1 {
                cut = remaining[0].lowerBound..<remaining[1].lowerBound
            } else {
                cut = remaining[0]
            }
            result.removeSubrange(cut)
            let shift = cut.count
            remaining.remove(at: index)
            for later in remaining.indices where later >= index {
                remaining[later] = (remaining[later].lowerBound - shift)..<(remaining[later].upperBound - shift)
            }
        }
        let output = Data(result)
        guard (try? JSONSerialization.jsonObject(with: output)) != nil else { return nil }
        return (output, matching.count)
    }

    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipSpace() {
            while let byte = peek, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 { index += 1 }
        }

        /// End of the string token starting at `index`, or `nil`.
        func skipString() -> Int? {
            guard peek == UInt8(ascii: "\"") else { return nil }
            var i = index + 1
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\\"): i += 2
                case UInt8(ascii: "\""): return i + 1
                default: i += 1
                }
            }
            return nil
        }

        /// End of the value starting at `index`, or `nil` when it is malformed.
        func skipValue() -> Int? {
            guard let first = peek else { return nil }
            if first == UInt8(ascii: "\"") { return skipString() }
            guard first == UInt8(ascii: "{") || first == UInt8(ascii: "[") else {
                var i = index
                while i < bytes.count, ![UInt8(ascii: ","), UInt8(ascii: "]"), UInt8(ascii: "}"), 0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
                return i > index ? i : nil
            }
            var depth = 0
            var i = index
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    guard let end = Scanner(bytes: bytes, index: i).skipString() else { return nil }
                    i = end
                    continue
                case UInt8(ascii: "{"), UInt8(ascii: "["):
                    depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"):
                    depth -= 1
                    if depth == 0 { return i + 1 }
                default:
                    break
                }
                i += 1
            }
            return nil
        }

        /// Ranges of the entries of the array starting at `index`.
        mutating func arrayEntries() -> [Range<Int>]? {
            index += 1
            var result: [Range<Int>] = []
            skipSpace()
            if peek == UInt8(ascii: "]") { return result }
            while true {
                skipSpace()
                guard let end = skipValue() else { return nil }
                result.append(index..<end)
                index = end
                skipSpace()
                if peek == UInt8(ascii: "]") { return result }
                guard peek == UInt8(ascii: ",") else { return nil }
                index += 1
            }
        }
    }
}
