import Foundation

/// One detection rule, gitleaks style: cheap keywords first, then a regular expression.
///
/// Patterns are ASCII only and run over the line decoded as ISO Latin-1, so one byte is one
/// UTF-16 unit and every match range is also an exact byte range in the file.
public struct SecretRule: Sendable, Hashable, Identifiable {
    public enum Mask: Sendable, Hashable {
        /// Show this many leading characters (a public prefix such as `sk-ant-`), then `…`,
        /// then the last four characters when the value is long enough.
        case prefix(Int)
        /// Show a fixed label instead of any part of the value.
        case label(String)
        /// Generic assignments: show the key name, never the start of the value.
        case keyName
    }

    public let id: String
    /// Plain name for the UI ("GitHub token").
    public let name: String
    /// At least one must occur (case-insensitive) before the expression runs.
    let keywords: [String]
    let pattern: String
    /// Capture group that holds the secret value; 0 is the whole match.
    let valueGroup: Int
    /// Capture group with the key name, for `.keyName` masks.
    let keyGroup: Int?
    /// Minimum Shannon entropy of the value in bits per character; 0 skips the check.
    let minEntropy: Double
    /// Generic values must mix letters and digits or symbols, and must not be a UUID or hash.
    let requiresMixedValue: Bool
    let mask: Mask
    /// `false` when a match is only part of the secret (a PEM header without its body).
    let isComplete: Bool
    /// Where a match can begin relative to a keyword, so the expression runs only there.
    let start: MatchStart

    /// Where a match begins relative to an occurrence of one of the rule's keywords. Every
    /// match of the pattern must satisfy it; the matcher tests rely on that.
    enum MatchStart: Sendable, Hashable {
        /// Exactly `offset` bytes after the keyword starts (negative: before it).
        case atKeyword(offset: Int)
        /// At most `before` bytes before the keyword starts, and no longer than `maxLength`.
        case nearKeyword(before: Int, maxLength: Int)
    }

    public static func == (a: SecretRule, b: SecretRule) -> Bool { a.id == b.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The rule for an id, or `nil` for an id this version does not know.
    public static func named(_ id: String) -> SecretRule? {
        all.first { $0.id == id }
    }

    /// Display name for an id, falling back to the id itself.
    public static func displayName(for id: String) -> String {
        named(id)?.name ?? id
    }

    /// Every rule, most specific first. Overlapping matches keep the earlier rule.
    public static let all: [SecretRule] = [
        SecretRule(
            id: "private-key", name: "Private key",
            keywords: ["-----begin "],
            pattern: #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----[A-Za-z0-9+/=\\\s:,.-]{16,16384}?-----END (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#,
            mask: .label("-----BEGIN PRIVATE KEY-----\u{2026}")
        ),
        SecretRule(
            id: "private-key-header", name: "Private key (start of block)",
            keywords: ["-----begin "],
            pattern: #"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#,
            mask: .label("-----BEGIN PRIVATE KEY-----\u{2026}"),
            isComplete: false
        ),
        SecretRule(
            id: "aws-access-key", name: "AWS access key",
            keywords: ["akia", "asia", "abia", "acca", "agpa", "aida", "aroa", "anpa", "anva", "aipa"],
            pattern: #"(?<![A-Za-z0-9])((?:AKIA|ASIA|ABIA|ACCA|AGPA|AIDA|AROA|ANPA|ANVA|AIPA)[A-Z0-9]{16})(?![A-Za-z0-9])"#,
            valueGroup: 1, mask: .prefix(4)
        ),
        SecretRule(
            id: "github-token", name: "GitHub token",
            keywords: ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"],
            pattern: #"(?<![A-Za-z0-9_])((?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36})(?![A-Za-z0-9_])"#,
            valueGroup: 1, mask: .prefix(4)
        ),
        SecretRule(
            id: "github-pat", name: "GitHub fine-grained token",
            keywords: ["github_pat_"],
            pattern: #"(?<![A-Za-z0-9_])(github_pat_[A-Za-z0-9_]{40,255})(?![A-Za-z0-9_])"#,
            valueGroup: 1, mask: .prefix(11)
        ),
        SecretRule(
            id: "anthropic-key", name: "Anthropic API key",
            keywords: ["sk-ant-"],
            pattern: #"(?<![A-Za-z0-9_-])(sk-ant-[A-Za-z0-9_-]{32,})"#,
            valueGroup: 1, minEntropy: 3.0, mask: .prefix(7)
        ),
        SecretRule(
            id: "openai-key", name: "OpenAI API key",
            keywords: ["sk-"],
            pattern: #"(?<![A-Za-z0-9_-])(sk-(?!ant-)(?:proj-|svcacct-|admin-)?[A-Za-z0-9_-]{32,})"#,
            valueGroup: 1, minEntropy: 3.0, requiresMixedValue: true, mask: .prefix(3)
        ),
        SecretRule(
            id: "slack-token", name: "Slack token",
            keywords: ["xox"],
            pattern: #"(?<![A-Za-z0-9])(xox[abposre]-[A-Za-z0-9-]{10,})"#,
            valueGroup: 1, mask: .prefix(5)
        ),
        SecretRule(
            id: "slack-webhook", name: "Slack webhook",
            keywords: ["hooks.slack.com"],
            pattern: #"(https://hooks\.slack\.com/services/[A-Za-z0-9_/-]{20,})"#,
            valueGroup: 1, mask: .label("https://hooks.slack.com/services/\u{2026}"),
            start: .atKeyword(offset: -8)
        ),
        SecretRule(
            id: "stripe-key", name: "Stripe secret key",
            keywords: ["sk_live_", "sk_test_", "rk_live_", "rk_test_"],
            pattern: #"(?<![A-Za-z0-9_])((?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,})"#,
            valueGroup: 1, mask: .prefix(8)
        ),
        SecretRule(
            id: "google-api-key", name: "Google API key",
            keywords: ["aiza"],
            pattern: #"(?<![A-Za-z0-9_-])(AIza[0-9A-Za-z_-]{35})(?![A-Za-z0-9_-])"#,
            valueGroup: 1, mask: .prefix(4)
        ),
        SecretRule(
            id: "jwt", name: "JSON Web Token",
            keywords: ["eyj"],
            pattern: #"(?<![A-Za-z0-9_-])(eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{16,})"#,
            valueGroup: 1, mask: .prefix(3)
        ),
        SecretRule(
            id: "generic-secret", name: "Password or key assignment",
            keywords: ["pass", "secret", "api", "key", "token"],
            pattern: #"(?i)(?<![A-Za-z0-9_])([A-Za-z0-9_.-]{0,40}(?:password|passwd|secret|api[_-]?key|access[_-]?key|auth[_-]?token|access[_-]?token|private[_-]?key)[A-Za-z0-9_.-]{0,40})\\?["']?[ \t]{0,3}[:=][ \t]{0,3}\\?["']?([A-Za-z0-9_+/=!@#$%^&*.~-]{10,128})"#,
            valueGroup: 2, keyGroup: 1, minEntropy: 3.2, requiresMixedValue: true, mask: .keyName,
            // The key word starts at most 40 bytes into the match, and a keyword sits at most
            // 8 bytes into the key word ("private_key"). Longest match: 40 + 12 + 40 key,
            // 11 separator, 128 value = 231.
            start: .nearKeyword(before: 48, maxLength: 240)
        ),
    ]

    init(
        id: String,
        name: String,
        keywords: [String],
        pattern: String,
        valueGroup: Int = 0,
        keyGroup: Int? = nil,
        minEntropy: Double = 0,
        requiresMixedValue: Bool = false,
        mask: Mask,
        isComplete: Bool = true,
        start: MatchStart = .atKeyword(offset: 0)
    ) {
        self.id = id
        self.name = name
        self.keywords = keywords
        self.pattern = pattern
        self.valueGroup = valueGroup
        self.keyGroup = keyGroup
        self.minEntropy = minEntropy
        self.requiresMixedValue = requiresMixedValue
        self.mask = mask
        self.isComplete = isComplete
        self.start = start
    }

    /// What a redaction writes in place of the value.
    public var replacement: String { "[REDACTED:\(id)]" }
}

// MARK: Value checks

enum SecretValue {
    /// Shannon entropy in bits per character.
    static func entropy(_ bytes: some Collection<UInt8>) -> Double {
        guard !bytes.isEmpty else { return 0 }
        var counts = [Int](repeating: 0, count: 256)
        for byte in bytes { counts[Int(byte)] += 1 }
        let total = Double(bytes.count)
        return counts.reduce(0.0) { sum, count in
            guard count > 0 else { return sum }
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }

    /// Mixed character classes, and not a UUID, hex hash, path or placeholder.
    static func looksLikeSecret(_ bytes: [UInt8]) -> Bool {
        let isHexOrDash = bytes.allSatisfy { isHex($0) || $0 == UInt8(ascii: "-") }
        if isHexOrDash { return false }
        // Placeholders (`$VAR`, `%s`, `***`) and paths (`/usr/...`, `~/...`, `./...`).
        if let first = bytes.first, Array("$%*/~.".utf8).contains(first) { return false }
        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        for placeholder in ["xxxx", "****", "....", "your_", "your-", "changeme", "placeholder", "redacted", "example", "process.env", "os.environ"]
        where text.contains(placeholder) {
            return false
        }
        var classes = 0
        if bytes.contains(where: { (97...122).contains($0) }) { classes += 1 }
        if bytes.contains(where: { (65...90).contains($0) }) { classes += 1 }
        if bytes.contains(where: { (48...57).contains($0) }) { classes += 1 }
        if bytes.contains(where: { !isAlphanumeric($0) }) { classes += 1 }
        // Words joined by dashes ("prod-db-password") are names, not secrets: two classes
        // count only when one of them is digits.
        let hasDigit = bytes.contains(where: { (48...57).contains($0) })
        return classes >= 3 || (classes == 2 && hasDigit)
    }

    static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte) || (65...70).contains(byte)
    }

    static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    /// `sk-ant-…a1B2`. Never more than the rule's public prefix and the last four characters.
    static func masked(_ bytes: [UInt8], key: String?, mask: SecretRule.Mask) -> String {
        let ellipsis = "\u{2026}"
        switch mask {
        case .label(let label):
            return label
        case .keyName:
            let tail = bytes.count >= 24 ? String(decoding: bytes.suffix(4), as: UTF8.self) : ""
            return "\(key ?? "secret")=\(ellipsis)\(tail)"
        case .prefix(let count):
            let shown = min(count, bytes.count / 3)
            let head = String(decoding: bytes.prefix(shown), as: UTF8.self)
            let tail = bytes.count >= 16 ? String(decoding: bytes.suffix(4), as: UTF8.self) : ""
            return head + ellipsis + tail
        }
    }
}
