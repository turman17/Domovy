import Foundation

/// Hides the values of scan findings in a transcript before it is parsed for display. Each
/// value is replaced by its masked preview (`sk-ant-…a1B2`) in the raw line, so the preview
/// pane never holds the secret. A line that cannot be masked safely is hidden whole.
public struct TranscriptMask: Sendable {
    private let byLine: [Int64: [SecretFinding]]

    /// Keeps the findings that belong to `file`.
    public init(findings: [SecretFinding], file: URL) {
        let path = file.standardizedFileURL.path
        byLine = Dictionary(grouping: findings.filter { $0.file.standardizedFileURL.path == path }, by: \.lineOffset)
    }

    public var isEmpty: Bool { byLine.isEmpty }

    /// The line with every finding masked; the line itself when it has none; `nil` when it
    /// must be hidden (the line moved since the scan, or masking would break its JSON).
    public func apply(_ line: Data, at offset: Int64) -> Data? {
        guard let findings = byLine[offset] else { return line }
        guard findings.allSatisfy({ $0.lineLength == line.count }) else { return nil }
        var bytes = [UInt8](line)
        for finding in findings.sorted(by: { $0.byteRange.lowerBound > $1.byteRange.lowerBound }) {
            let range = finding.rangeInLine
            guard range.lowerBound >= 0, range.upperBound <= bytes.count, JSONText.isInsideString(range, of: bytes) else { return nil }
            bytes.replaceSubrange(range, with: Array(Self.jsonSafe(finding.preview).utf8))
        }
        let masked = Data(bytes)
        return JSONText.isValidJSON(masked) ? masked : nil
    }

    /// The preview without quotes, backslashes or control characters, so it fits in a JSON string.
    static func jsonSafe(_ preview: String) -> String {
        let safe = preview.unicodeScalars.filter { $0 != "\"" && $0 != "\\" && $0.value >= 0x20 }
        let text = String(String.UnicodeScalarView(safe))
        return text.isEmpty ? "[secret]" : text
    }
}
