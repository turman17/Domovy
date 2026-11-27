@testable import DomovyCore
import Foundation

/// The secret matcher as it was before the prefilter and anchored matching: every rule whose
/// keyword occurs runs its expression over the whole line. Kept as the reference the fast
/// matcher must agree with exactly.
final class ReferenceSecretMatcher {
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
