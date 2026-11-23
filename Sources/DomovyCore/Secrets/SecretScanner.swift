import Foundation

/// Finds possible secrets in session files. Streams each file line by line, so memory stays
/// bounded, and checks for cancellation as it goes. Runs wherever the caller runs it; the app
/// calls it from a detached task. What it reads stays in memory (safety rule 7): findings
/// hold masked previews only, and the only thing logged is a count.
public struct SecretScanner: Sendable {
    public let maxLineBytes: Int

    public init(maxLineBytes: Int = 4 << 20) {
        self.maxLineBytes = maxLineBytes
    }

    /// The files of each session worth reading: transcripts, set-aside copies and everything
    /// below the session's folders. Shared index files (`history.jsonl`) are left out.
    public static func targets(for sessions: [Session], adapters: [any AgentAdapter]) async -> [SecretScanTarget] {
        var targets: [SecretScanTarget] = []
        for session in sessions {
            guard let adapter = adapters.first(where: { $0.kind == session.agent }),
                  let artifacts = try? await adapter.artifacts(of: session) else { continue }
            targets.append(SecretScanTarget(session: session, files: files(of: artifacts)))
        }
        return targets
    }

    static func files(of artifacts: [Artifact]) -> [URL] {
        var files: [URL] = []
        for artifact in artifacts {
            switch artifact.kind {
            case .indexEntry:
                continue
            case .file:
                if APFSCompression.isRegularFile(artifact.url) { files.append(artifact.url) }
            case .folder:
                guard let enumerator = FileManager.default.enumerator(at: artifact.url, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
                let found = enumerator.compactMap { $0 as? URL }.map(\.standardizedFileURL).filter(APFSCompression.isRegularFile)
                files += found.sorted { $0.path < $1.path }
            }
        }
        return files
    }

    /// Scans every target. Throws `CancellationError` when the task is cancelled.
    public func scan(
        _ targets: [SecretScanTarget],
        progress: @Sendable (SecretScanProgress) -> Void = { _ in }
    ) async throws -> SecretScanReport {
        let matcher = SecretMatcher()
        var report = SecretScanReport()
        for (index, target) in targets.enumerated() {
            for file in target.files {
                try Task.checkCancellation()
                switch try scanFile(file, session: target.session, matcher: matcher) {
                case .scanned(let findings, let bytes):
                    report.findings += findings
                    report.filesScanned += 1
                    report.bytesScanned += bytes
                case .skipped(let reason):
                    report.skipped.append(SkippedFile(sessionID: target.session.id, file: file, reason: reason))
                case .ignored:
                    break
                }
            }
            report.sessionsScanned += 1
            progress(SecretScanProgress(sessionsDone: index + 1, sessionsTotal: targets.count, findings: report.findings.count))
            await Task.yield()
        }
        SecretsLog.scanFinished(findings: report.findings.count, files: report.filesScanned, skipped: report.skipped.count)
        return report
    }

    /// One session's findings, for the CLI and for checking a redaction afterwards.
    public func scan(_ session: Session, adapter: any AgentAdapter) async throws -> SecretScanReport {
        try await scan(Self.targets(for: [session], adapters: [adapter]))
    }

    enum FileResult {
        case scanned([SecretFinding], bytes: Int64)
        case skipped(String)
        /// Binary content such as images; nothing to say about it.
        case ignored
    }

    static let binaryExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "zip", "gz", "sqlite", "db", "img"]

    func scanFile(_ url: URL, session: Session, matcher: SecretMatcher) throws -> FileResult {
        let name = url.lastPathComponent
        if name.hasSuffix(".zst") { return .skipped("It is compressed with zstd, which Domovy cannot read yet.") }
        if Self.binaryExtensions.contains(url.pathExtension.lowercased()) { return .ignored }
        if Self.looksBinary(url) { return .ignored }
        let isJSONLines = name.hasSuffix(".jsonl") || name.contains(".jsonl.") || name.contains(".jsonl-")

        var stream: LineStream
        do {
            stream = try LineStream(url: url, maxLineBytes: maxLineBytes)
        } catch {
            return .skipped("Domovy could not open it: \(error.localizedDescription)")
        }
        defer { stream.close() }

        var findings: [SecretFinding] = []
        var seen = Set<Int64>()
        var bytes: Int64 = 0
        var checked = 0
        while let line = try stream.next() {
            checked += 1
            if checked % 512 == 0, Task.isCancelled { throw CancellationError() }
            bytes = line.offset + Int64(line.bytes.count)
            let matches = matcher.matches(in: line.bytes)
            guard !matches.isEmpty else { continue }
            let lineBytes = [UInt8](line.bytes)
            let validJSON = isJSONLines && !line.isPartial && JSONText.isValidJSON(line.bytes)
            for match in matches {
                let start = line.offset + Int64(match.range.lowerBound)
                guard seen.insert(start).inserted else { continue }
                findings.append(SecretFinding(
                    sessionID: session.id,
                    agent: session.agent,
                    file: url,
                    line: line.number,
                    ruleID: match.ruleID,
                    preview: match.preview,
                    byteRange: start..<(line.offset + Int64(match.range.upperBound)),
                    lineOffset: line.offset,
                    lineLength: line.bytes.count,
                    redaction: Self.redaction(for: match, in: lineBytes, isJSONLines: isJSONLines, isPartial: line.isPartial, validJSON: validJSON)
                ))
            }
        }
        return .scanned(findings, bytes: bytes)
    }

    /// A NUL byte in the first 8 KB: an image or other binary, not text.
    private static func looksBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 8192))?.contains(0) ?? false
    }

    private static func redaction(for match: LineMatch, in line: [UInt8], isJSONLines: Bool, isPartial: Bool, validJSON: Bool) -> SecretFinding.Redaction {
        if SecretRule.named(match.ruleID)?.isComplete == false {
            return .notRedactable(reason: "Only the start of the key block is on this line, so Domovy cannot redact all of it.")
        }
        guard isJSONLines else { return .notRedactable(reason: "Not a JSON lines transcript. Domovy only redacts inside JSON strings; delete the session to remove it.") }
        guard !isPartial else { return .notRedactable(reason: "The line is too long to rewrite safely.") }
        guard validJSON else { return .notRedactable(reason: "The line is not valid JSON.") }
        guard JSONText.isInsideString(match.range, of: line) else { return .notRedactable(reason: "It is not inside a JSON string value.") }
        return .inJSONString
    }
}

/// The only logging the secret scan does: counts, public. There is no way to pass it text.
enum SecretsLog {
    static func scanFinished(findings: Int, files: Int, skipped: Int) {
        Log.secrets.info("Secret scan finished: \(findings, privacy: .public) findings in \(files, privacy: .public) files, \(skipped, privacy: .public) skipped")
    }

    static func redacted(replacements: Int, files: Int) {
        Log.secrets.info("Redacted \(replacements, privacy: .public) values in \(files, privacy: .public) files")
    }

    static func purged(files: Int) {
        Log.secrets.info("Purged \(files, privacy: .public) quarantined originals")
    }
}
