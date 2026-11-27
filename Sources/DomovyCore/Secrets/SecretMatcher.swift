import Foundation

/// A match inside one line. Holds positions only; the value itself never leaves `SecretMatcher`.
struct LineMatch: Hashable, Sendable {
    let ruleID: String
    /// Byte range of the secret value within the line.
    let range: Range<Int>
    /// Masked preview, computed while the value was in hand.
    let preview: String
}

/// The rule set compiled for one scan. Not shared across threads; each scan task builds its
/// own (the compiled expressions themselves are shared, they are immutable).
///
/// A line is first searched for every rule's keywords in one pass over its bytes, without
/// copying it. Each rule's expression then runs only where a match can start next to one of
/// its keywords (`SecretRule.MatchStart`), so the findings are exactly those of running every
/// candidate rule over the whole line.
final class SecretMatcher {
    private struct Compiled: @unchecked Sendable {
        let rule: SecretRule
        /// `NSRegularExpression` is immutable and documented as safe to use from any thread.
        let regex: NSRegularExpression
    }

    /// Keywords in one table: the first two lowercased bytes select a bucket of candidates.
    private struct Keywords: Sendable {
        /// Lowercased keyword bytes and the index of their rule.
        let words: [(bytes: [UInt8], rule: Int)]
        /// Bucket number (0 = none) for each pair of lowercased leading bytes.
        let table: [UInt8]
        /// Keyword indices per bucket.
        let buckets: [[Int]]

        init(_ rules: [SecretRule]) {
            var words: [(bytes: [UInt8], rule: Int)] = []
            for (index, rule) in rules.enumerated() {
                for keyword in rule.keywords {
                    let bytes = keyword.utf8.map(SecretMatcher.lowercase)
                    // Every keyword has at least two bytes (tested); a shorter one could not be indexed.
                    guard bytes.count >= 2 else { continue }
                    words.append((bytes, index))
                }
            }
            var table = [UInt8](repeating: 0, count: 1 << 16)
            var buckets: [[Int]] = [[]]
            for (index, word) in words.enumerated() {
                let key = Int(word.bytes[0]) << 8 | Int(word.bytes[1])
                if table[key] == 0, buckets.count < 256 {
                    table[key] = UInt8(buckets.count)
                    buckets.append([])
                }
                buckets[Int(table[key])].append(index)
            }
            self.words = words
            self.table = table
            self.buckets = buckets
        }
    }

    private struct Shared: @unchecked Sendable {
        let compiled: [Compiled]
        let keywords: Keywords

        init(rules: [SecretRule]) {
            // The patterns are constants covered by tests; a bad one is skipped, never fatal.
            compiled = rules.compactMap { rule in
                (try? NSRegularExpression(pattern: rule.pattern)).map { Compiled(rule: rule, regex: $0) }
            }
            keywords = Keywords(compiled.map(\.rule))
        }
    }

    private static let standard = Shared(rules: SecretRule.all)

    private let shared: Shared
    /// Keyword positions per rule for the current line; reused between lines.
    private var positions: [[Int]]

    init(rules: [SecretRule] = SecretRule.all) {
        shared = rules == SecretRule.all ? Self.standard : Shared(rules: rules)
        positions = Array(repeating: [], count: shared.compiled.count)
    }

    static func lowercase(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    /// Every finding in `line`, most specific rule first, with overlaps removed.
    func matches(in line: Data) -> [LineMatch] {
        guard !line.isEmpty else { return [] }
        let bytes = [UInt8](line)
        guard findKeywords(in: bytes) else { return [] }

        // Latin-1 keeps one byte per UTF-16 unit, so NSRange offsets are byte offsets.
        guard let text = NSString(bytes: bytes, length: bytes.count, encoding: String.Encoding.isoLatin1.rawValue) else { return [] }
        let string = text as String
        var accepted: [LineMatch] = []
        for (index, item) in shared.compiled.enumerated() where !positions[index].isEmpty {
            for result in Self.results(of: item, in: string, length: bytes.count, keywordsAt: positions[index]) {
                let valueRange = result.range(at: item.rule.valueGroup)
                guard valueRange.location != NSNotFound,
                      let range = Range(valueRange),
                      !accepted.contains(where: { $0.range.overlaps(range) }) else { continue }
                let value = Array(bytes[range])
                if item.rule.minEntropy > 0, SecretValue.entropy(value) < item.rule.minEntropy { continue }
                if item.rule.requiresMixedValue, !SecretValue.looksLikeSecret(value) { continue }
                var key: String?
                if let group = item.rule.keyGroup, let keyRange = Range(result.range(at: group)) {
                    key = String(decoding: bytes[keyRange], as: UTF8.self)
                }
                accepted.append(LineMatch(ruleID: item.rule.id, range: range, preview: SecretValue.masked(value, key: key, mask: item.rule.mask)))
            }
        }
        return accepted.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// Fills `positions` with where each rule's keywords occur, ignoring ASCII case. `true`
    /// when any occurs.
    private func findKeywords(in bytes: [UInt8]) -> Bool {
        for index in positions.indices where !positions[index].isEmpty { positions[index].removeAll(keepingCapacity: true) }
        let keywords = shared.keywords
        var found = false
        bytes.withUnsafeBufferPointer { line in
            keywords.table.withUnsafeBufferPointer { table in
                let count = line.count
                guard count >= 2 else { return }
                var pair = Int(Self.lowercase(line[0]))
                for start in 0..<(count - 1) {
                    pair = (pair & 0xFF) << 8 | Int(Self.lowercase(line[start + 1]))
                    let bucket = table[pair]
                    guard bucket != 0 else { continue }
                    for wordIndex in keywords.buckets[Int(bucket)] {
                        let word = keywords.words[wordIndex]
                        guard start + word.bytes.count <= count else { continue }
                        var offset = 2
                        while offset < word.bytes.count, Self.lowercase(line[start + offset]) == word.bytes[offset] { offset += 1 }
                        guard offset == word.bytes.count else { continue }
                        positions[word.rule].append(start)
                        found = true
                    }
                }
            }
        }
        return found
    }

    /// The matches a search of the whole line would find, in order, found by searching only
    /// where the rule says a match can start.
    private static func results(of item: Compiled, in text: String, length: Int, keywordsAt keywords: [Int]) -> [NSTextCheckingResult] {
        var results: [NSTextCheckingResult] = []
        // A whole-line search resumes after each match; so do these.
        var resume = 0
        switch item.rule.start {
        case .atKeyword(let offset):
            var previous = -1
            for keyword in keywords {
                let start = keyword + offset
                guard start >= resume, start != previous, start < length else { continue }
                previous = start
                if let result = item.regex.firstMatch(in: text, options: [.anchored, .withTransparentBounds],
                                                      range: NSRange(location: start, length: length - start)) {
                    results.append(result)
                    resume = NSMaxRange(result.range)
                }
            }
        case .nearKeyword(let before, let maxLength):
            // Windows of possible starts, merged while their search ranges touch, so a match
            // is never cut short by a window's end.
            var index = 0
            while index < keywords.count {
                let low = max(0, keywords[index] - before)
                var high = keywords[index]
                index += 1
                while index < keywords.count, max(0, keywords[index] - before) <= min(length, high + maxLength) {
                    high = keywords[index]
                    index += 1
                }
                let from = max(low, resume)
                let end = min(length, high + maxLength)
                guard from < end else { continue }
                for result in item.regex.matches(in: text, options: [.withTransparentBounds, .withoutAnchoringBounds],
                                                 range: NSRange(location: from, length: end - from)) {
                    results.append(result)
                    resume = NSMaxRange(result.range)
                }
            }
        }
        return results
    }
}

/// Where a byte range sits in one line of JSON.
enum JSONText {
    /// `true` when `range` lies inside the contents of one JSON string token and neither end
    /// splits an escape sequence, so replacing it with plain ASCII keeps the line valid JSON.
    static func isInsideString(_ range: Range<Int>, of bytes: [UInt8]) -> Bool {
        var i = 0
        let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\")
        while i < bytes.count {
            guard bytes[i] == quote else {
                i += 1
                continue
            }
            let contentStart = i + 1
            var j = contentStart
            var splitsEscape = false
            while j < bytes.count, bytes[j] != quote {
                if bytes[j] == backslash {
                    let length = j + 1 < bytes.count && bytes[j + 1] == UInt8(ascii: "u") ? 6 : 2
                    let escape = j..<(j + length)
                    if (escape.lowerBound + 1..<escape.upperBound).contains(range.lowerBound)
                        || (escape.lowerBound + 1..<escape.upperBound).contains(range.upperBound) {
                        splitsEscape = true
                    }
                    j += length
                } else {
                    j += 1
                }
            }
            let contentEnd = min(j, bytes.count)
            if range.lowerBound >= contentStart, range.upperBound <= contentEnd {
                return !splitsEscape && j < bytes.count
            }
            if range.lowerBound < contentEnd { return false }
            i = j + 1
        }
        return false
    }

    static func isValidJSON(_ line: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])) != nil
    }
}
