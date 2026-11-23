import Foundation

/// One possible secret in a session's files. It carries where the secret is and a masked
/// preview, never the value itself, so printing, encoding or logging a finding cannot leak it.
public struct SecretFinding: Identifiable, Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Redaction: Hashable, Codable, Sendable {
        /// Inside a JSON string value: replacing it keeps the line valid JSON.
        case inJSONString
        /// Domovy leaves it alone, for this reason.
        case notRedactable(reason: String)
    }

    public let sessionID: String
    public let agent: AgentKind
    public let file: URL
    /// One-based line number.
    public let line: Int
    public let ruleID: String
    /// `sk-ant-…a1B2`: a public prefix and at most the last four characters.
    public let preview: String
    /// Byte range of the value in the file.
    public let byteRange: Range<Int64>
    /// Where the line starts in the file and how long it is (without its newline).
    public let lineOffset: Int64
    public let lineLength: Int
    public let redaction: Redaction

    public var id: String { "\(file.path)#\(byteRange.lowerBound)" }
    public var ruleName: String { SecretRule.displayName(for: ruleID) }
    public var isRedactable: Bool { redaction == .inJSONString }

    /// Range of the value within its line.
    var rangeInLine: Range<Int> {
        Int(byteRange.lowerBound - lineOffset)..<Int(byteRange.upperBound - lineOffset)
    }

    public var description: String {
        "\(ruleID) in \(file.lastPathComponent):\(line) \(preview)"
    }
}

/// A file the scan could not read, with the reason in plain words.
public struct SkippedFile: Hashable, Codable, Sendable {
    public let sessionID: String
    public let file: URL
    public let reason: String
}

/// The result of one scan. Kept in memory only; Domovy never writes it to disk.
public struct SecretScanReport: Sendable {
    public var findings: [SecretFinding] = []
    public var skipped: [SkippedFile] = []
    public var sessionsScanned = 0
    public var filesScanned = 0
    public var bytesScanned: Int64 = 0

    public init() {}

    public var sessionsWithFindings: Int { Set(findings.map(\.sessionID)).count }

    /// Findings grouped by session id.
    public var findingsBySession: [String: [SecretFinding]] { Dictionary(grouping: findings, by: \.sessionID) }

    /// "Found 7 possible secrets in 3 sessions." / "No secrets found in 12 sessions."
    public var summary: String {
        let scanned = "\(sessionsScanned) \(sessionsScanned == 1 ? "session" : "sessions")"
        guard !findings.isEmpty else { return "No secrets found in \(scanned)." }
        let n = findings.count, s = sessionsWithFindings
        return "Found \(n) possible \(n == 1 ? "secret" : "secrets") in \(s) \(s == 1 ? "session" : "sessions")."
    }
}

/// Progress of a running scan, reported after each file.
public struct SecretScanProgress: Sendable {
    public let sessionsDone: Int
    public let sessionsTotal: Int
    public let findings: Int

    public var fraction: Double { sessionsTotal == 0 ? 1 : Double(sessionsDone) / Double(sessionsTotal) }
}

/// The files of one session the scan reads.
public struct SecretScanTarget: Sendable {
    public let session: Session
    public let files: [URL]

    public init(session: Session, files: [URL]) {
        self.session = session
        self.files = files
    }
}
