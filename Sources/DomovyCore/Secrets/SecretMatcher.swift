import Foundation

/// A match inside one line. Holds positions only; the value itself never leaves `SecretMatcher`.
struct LineMatch: Hashable, Sendable {
    let ruleID: String
    /// Byte range of the secret value within the line.
    let range: Range<Int>
    /// Masked preview, computed while the value was in hand.
    let preview: String
}

/// The rule set compiled for one scan. Not shared across threads; each scan builds its own.
final class SecretMatcher {
    private struct Compiled {
        let rule: SecretRule
        let regex: NSRegularExpression
        let keywords: [Data]
    }

    private let compiled: [Compiled]

    init(rules: [SecretRule] = SecretRule.all) {
        compiled = rules.compactMap { rule in
            // The patterns are constants covered by tests; a bad one is skipped, never fatal.
            guard let regex = try? NSRegularExpression(pattern: rule.pattern) else { return nil }
            return Compiled(rule: rule, regex: regex, keywords: rule.keywords.map { Data($0.lowercased().utf8) })
        }
    }

    /// Every finding in `line`, most specific rule first, with overlaps removed.
    func matches(in line: Data) -> [LineMatch] {
        guard !line.isEmpty else { return [] }
        let lowered = Data(line.map { (65...90).contains($0) ? $0 + 32 : $0 })
        let candidates = compiled.filter { rule in rule.keywords.contains { lowered.range(of: $0) != nil } }
        guard !candidates.isEmpty else { return [] }

        // Latin-1 keeps one byte per UTF-16 unit, so NSRange offsets are byte offsets.
        guard let text = String(data: line, encoding: .isoLatin1) else { return [] }
        let bytes = [UInt8](line)
        let whole = NSRange(location: 0, length: (text as NSString).length)
        var accepted: [LineMatch] = []
        for item in candidates {
            for result in item.regex.matches(in: text, range: whole) {
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
