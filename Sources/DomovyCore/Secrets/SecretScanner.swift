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
    /// below the session's folders, plus the session's own lines of shared index files that
    /// say which lines are whose (Claude Code's `history.jsonl`). Sessions are looked up a few
    /// at a time; the result keeps their order.
    public static func targets(for sessions: [Session], adapters: [any AgentAdapter]) async -> [SecretScanTarget] {
        var found = [SecretScanTarget?](repeating: nil, count: sessions.count)
        do {
            try await inParallel(sessions.count) { index -> SecretScanTarget? in
                let session = sessions[index]
                guard let adapter = adapters.first(where: { $0.kind == session.agent }),
                      let artifacts = try? await adapter.artifacts(of: session) else { return nil }
                return SecretScanTarget(session: session, files: files(of: artifacts), indexLines: indexLines(of: artifacts))
            } receive: { index, target in
                found[index] = target
            }
        } catch {
            // Nothing above throws: a session whose artifacts cannot be read is left out.
        }
        return found.compactMap { $0 }
    }

    /// Runs `work` for `0..<count`, at most one task per processor at a time, and hands each
    /// result to `receive` on the calling task as it finishes. The first error stops the rest.
    static func inParallel<Result: Sendable>(
        _ count: Int,
        work: @escaping @Sendable (Int) async throws -> Result,
        receive: (Int, Result) throws -> Void
    ) async throws {
        let limit = max(1, ProcessInfo.processInfo.activeProcessorCount)
        try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            var next = 0
            func start() {
                let index = next
                group.addTask { (index, try await work(index)) }
                next += 1
            }
            while next < min(count, limit) { start() }
            while let (index, result) = try await group.next() {
                try receive(index, result)
                if next < count { start() }
            }
        }
    }

    static func indexLines(of artifacts: [Artifact]) -> [IndexLines] {
        artifacts.compactMap { artifact in
            guard artifact.kind == .indexEntry, let match = artifact.match, APFSCompression.isRegularFile(artifact.url) else { return nil }
            return IndexLines(file: artifact.url, match: match)
        }
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

    /// Scans every target, several files at a time. Findings come out in the order of the
    /// targets and their files, then the shared index files, whatever order the reads finish
    /// in. Throws `CancellationError` when the task is cancelled.
    public func scan(
        _ targets: [SecretScanTarget],
        progress: @Sendable (SecretScanProgress) -> Void = { _ in }
    ) async throws -> SecretScanReport {
        enum Job: Sendable {
            case file(URL, target: Int)
            /// One pass per shared index file, however many sessions have lines in it.
            case index(URL, owners: [(IndexLines, Session)])
        }
        var jobs: [Job] = []
        for (index, target) in targets.enumerated() {
            jobs += target.files.map { .file($0, target: index) }
        }
        let shared = Dictionary(grouping: targets.flatMap { target in target.indexLines.map { ($0, target.session) } }, by: { $0.0.file })
        jobs += shared.sorted(by: { $0.key.path < $1.key.path }).map { .index($0.key, owners: $0.value) }

        // A session counts as done once all its files are read.
        var remaining = targets.map(\.files.count)
        var sessionsDone = 0, findingsSoFar = 0
        func sessionFinished() {
            sessionsDone += 1
            progress(SecretScanProgress(sessionsDone: sessionsDone, sessionsTotal: targets.count, findings: findingsSoFar))
        }
        for count in remaining where count == 0 { sessionFinished() }

        var results = [FileResult?](repeating: nil, count: jobs.count)
        let allJobs = jobs
        try await Self.inParallel(jobs.count) { [self] index -> FileResult in
            try Task.checkCancellation()
            let matcher = SecretMatcher()
            switch allJobs[index] {
            case .file(let url, let target): return try scanFile(url, session: targets[target].session, matcher: matcher)
            case .index(let url, let owners): return try scanIndexFile(url, owners: owners, matcher: matcher)
            }
        } receive: { index, result in
            results[index] = result
            if case .scanned(let findings, _) = result { findingsSoFar += findings.count }
            if case .file(_, let target) = jobs[index] {
                remaining[target] -= 1
                if remaining[target] == 0 { sessionFinished() }
            }
        }

        var report = SecretScanReport()
        report.sessionsScanned = targets.count
        for (job, result) in zip(jobs, results) {
            switch result {
            case .scanned(let findings, let bytes):
                report.findings += findings
                report.filesScanned += 1
                report.bytesScanned += bytes
            case .skipped(let reason):
                switch job {
                case .file(let file, let target):
                    report.skipped.append(SkippedFile(sessionID: targets[target].session.id, file: file, reason: reason))
                case .index(let file, let owners):
                    for (_, session) in owners { report.skipped.append(SkippedFile(sessionID: session.id, file: file, reason: reason)) }
                }
            case .ignored, nil:
                break
            }
        }
        SecretsLog.scanFinished(findings: report.findings.count, files: report.filesScanned, skipped: report.skipped.count)
        return report
    }

    /// One session's findings, for the CLI and for checking a redaction afterwards.
    public func scan(_ session: Session, adapter: any AgentAdapter) async throws -> SecretScanReport {
        try await scan(Self.targets(for: [session], adapters: [adapter]))
    }

    enum FileResult: Sendable {
        case scanned([SecretFinding], bytes: Int64)
        case skipped(String)
        /// Binary content such as images; nothing to say about it.
        case ignored
    }

    static let compressedReason = "It is in a zstd-compressed rollout, which Domovy reads but does not rewrite. Deleting the session removes it."

    static let binaryExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "pdf", "zip", "gz", "sqlite", "db", "img"]

    func scanFile(_ url: URL, session: Session, matcher: SecretMatcher) throws -> FileResult {
        let name = url.lastPathComponent
        let isZstd = name.hasSuffix(".zst")
        if !isZstd, Self.binaryExtensions.contains(url.pathExtension.lowercased()) { return .ignored }
        if !isZstd, Self.looksBinary(url) { return .ignored }
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
        while true {
            let next: LineStream.Line?
            do {
                next = try stream.next()
            } catch let error as ZstdError {
                return .skipped(error.localizedDescription)
            }
            guard let line = next else { break }
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
                    redaction: isZstd
                        ? .notRedactable(reason: Self.compressedReason)
                        : Self.redaction(for: match, in: lineBytes, isJSONLines: isJSONLines, isPartial: line.isPartial, validJSON: validJSON)
                ))
            }
        }
        return .scanned(findings, bytes: bytes)
    }

    /// Scans the lines of a shared index file that belong to one of `owners`. A line is parsed
    /// only when the matcher found something in it, to see whose it is.
    func scanIndexFile(_ url: URL, owners: [(IndexLines, Session)], matcher: SecretMatcher) throws -> FileResult {
        var stream: LineStream
        do {
            stream = try LineStream(url: url, maxLineBytes: maxLineBytes)
        } catch {
            return .skipped("Domovy could not open it: \(error.localizedDescription)")
        }
        defer { stream.close() }
        let keys = Set(owners.map(\.0.match.key))
        var sessions: [String: Session] = [:]
        for (lines, session) in owners { sessions[lines.match.value.lowercased()] = session }

        var findings: [SecretFinding] = []
        var bytes: Int64 = 0
        var checked = 0
        while let line = try stream.next() {
            checked += 1
            if checked % 512 == 0, Task.isCancelled { throw CancellationError() }
            bytes = line.offset + Int64(line.bytes.count)
            guard !line.isPartial else { continue }
            let matches = matcher.matches(in: line.bytes)
            guard !matches.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line.bytes) as? [String: Any],
                  let session = keys.lazy.compactMap({ (object[$0] as? String).flatMap { sessions[$0.lowercased()] } }).first else { continue }
            let lineBytes = [UInt8](line.bytes)
            for match in matches {
                let start = line.offset + Int64(match.range.lowerBound)
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
                    redaction: Self.redaction(for: match, in: lineBytes, isJSONLines: true, isPartial: false, validJSON: true)
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
