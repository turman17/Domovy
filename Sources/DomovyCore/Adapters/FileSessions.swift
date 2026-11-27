import Foundation

/// Pieces shared by adapters whose sessions are plain files or folders (Qwen Code, Kimi CLI,
/// Roo Code, Continue): the live check from the agent's own markers plus open file handles, the
/// stricter check before a plan, and the APFS compressions of an archive.
enum FileSessions {
    /// Live when a marker reason fired or a process holds one of the session's files open.
    /// `holders` is `nil` when the open-file check could not run.
    static func liveness(markers: [String], holders: [OpenHandleHolder]?, signals: [String]) -> LiveCheckResult {
        var reasons = markers
        let status: LiveCheckResult.OpenHandleStatus
        if let holders {
            status = holders.isEmpty ? .clear : .open
            var seen = Set<Int32>()
            for holder in holders where seen.insert(holder.pid).inserted {
                reasons.append("\(holder.processName) (pid \(holder.pid)) has a file of this session open.")
            }
        } else {
            status = .unavailable
        }
        return LiveCheckResult(isLive: !reasons.isEmpty, reasons: reasons, checkedSignals: signals + ["open file handles"], openHandles: status)
    }

    /// Before a delete: the agent must also be quit (`blocking` from `blockingReasons`).
    static func forPlan(_ base: LiveCheckResult, blocking: [String], app: String) -> LiveCheckResult {
        LiveCheckResult(isLive: base.isLive || !blocking.isEmpty, reasons: base.reasons + blocking,
                        checkedSignals: base.checkedSignals + ["\(app) processes"], openHandles: base.openHandles)
    }

    /// Compressions for the regular files below each artifact, skipping what is already
    /// compressed, too small to gain, or a lock file. A protected path stops the plan.
    static func compressions(of artifacts: [Artifact], isProtected: (URL) -> Bool) throws -> [FileCompression] {
        var result: [FileCompression] = []
        for artifact in artifacts where artifact.kind != .indexEntry {
            for file in APFSCompression.regularFiles(at: artifact.url) {
                if isProtected(file) { throw AdapterError.protectedPathInPlan(file) }
                guard !file.lastPathComponent.hasSuffix(".lock"), !APFSCompression.isCompressed(file),
                      FileSystem.size(of: file) > APFSCompression.minimumUsefulSize else { continue }
                result.append(FileCompression(
                    file: file,
                    sizeBytes: APFSCompression.allocatedBytes(of: file),
                    estimatedBytes: APFSCompression.estimatedCompressedBytes(of: file),
                    modificationTime: FileSystem.modificationTime(of: file),
                    note: artifact.note
                ))
            }
        }
        return result
    }

    /// One JSON object from a file, or `nil`.
    static func object(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// The first line of `text`, trimmed and shortened for a list, or `nil` when empty.
    static func title(_ text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "\u{2026}" : line
    }

    /// ISO 8601 with or without fractional seconds.
    static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    /// Seconds or milliseconds since 1970, as a number or numeric string.
    static func epoch(_ value: Any?) -> Date? {
        let number: Double?
        switch value {
        case let n as NSNumber: number = n.doubleValue
        case let s as String: number = Double(s)
        default: number = nil
        }
        guard let number, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number > 100_000_000_000 ? number / 1000 : number)
    }

    /// Up to `maxMessages` messages of a JSON-lines transcript, after masking scan findings line
    /// by line; `message` turns one record into a message (or `nil` to skip it). Reads a bounded
    /// prefix; content is never logged.
    static func readJSONLines(of file: URL, maxMessages: Int, maxBytes: Int = 4 * 1024 * 1024, masking findings: [SecretFinding],
                              message: ([String: Any], Int) -> TranscriptMessage?) throws -> Transcript {
        let mask = TranscriptMask(findings: findings, file: file)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: file)
        } catch {
            throw AdapterError.unreadable(file, reason: error.localizedDescription)
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? Data()
        var truncated = data.count > maxBytes
        let budget = data.prefix(maxBytes)
        var lines = budget.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if truncated, budget.last != UInt8(ascii: "\n"), !lines.isEmpty { lines.removeLast() }
        var messages: [TranscriptMessage] = []
        var hidden = 0
        for raw in lines {
            guard let line = mask.apply(Data(raw), at: Int64(raw.startIndex - data.startIndex)) else {
                hidden += 1
                continue
            }
            guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let item = message(record, messages.count) else { continue }
            if messages.count >= maxMessages {
                truncated = true
                break
            }
            messages.append(item)
        }
        return Transcript(messages: messages, isTruncated: truncated, hiddenLineCount: hidden)
    }

    /// The newest `limit` messages of a JSON-lines transcript before `cursor`, read from the
    /// end; `message` gets each record and its line's byte offset.
    static func readJSONLinesPage(of file: URL, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding],
                                  message: ([String: Any], Int) -> TranscriptMessage?) throws -> Transcript {
        try TranscriptTail.page(of: file, limit: limit, before: cursor, masking: findings) { lines in
            lines.compactMap { line in
                guard let record = try? JSONSerialization.jsonObject(with: line.data) as? [String: Any] else { return nil }
                return message(record, Int(line.offset)).map { (line.offset, $0) }
            }
        }
    }

    /// JSON objects of the first `maxBytes` of a JSON-lines file; a cut-off last line is skipped.
    static func records(in file: URL, maxBytes: Int = 256 * 1024) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes + 1), !data.isEmpty else { return [] }
        let complete = data.count <= maxBytes
        var lines = data.prefix(maxBytes).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !complete, !lines.isEmpty { lines.removeLast() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    /// JSON objects of the last `maxBytes` of a JSON-lines file; a cut-off first line is skipped.
    static func tailRecords(in file: URL, maxBytes: Int = 64 * 1024) -> [[String: Any]] {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return [] }
        defer { try? handle.close() }
        let size = FileSystem.size(of: file)
        guard size > maxBytes else { return records(in: file, maxBytes: maxBytes) }
        guard (try? handle.seek(toOffset: UInt64(size - Int64(maxBytes)))) != nil,
              let data = try? handle.read(upToCount: maxBytes) else { return [] }
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
    }

    /// Text of a message's content: a string, or the `text` of its parts (`[{type: text, text}]`
    /// or Gemini-style `[{text}]`), joined by newlines.
    static func text(of content: Any?) -> String? {
        if let string = content as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let parts = content as? [Any] else { return nil }
        let texts = parts.compactMap { part -> String? in
            guard let part = part as? [String: Any], part["type"] == nil || part["type"] as? String == "text" else { return nil }
            return part["text"] as? String
        }
        let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Plans for a batch of sessions: each is located first, then one open-file question covers
    /// every session's files, and `finish` builds each plan from its own live check. One session
    /// that cannot be located or planned does not stop the others.
    static func plans<Target>(
        for sessions: [Session], checker: any OpenHandleChecker,
        locate: (Session) throws -> Target, files: (Target) -> [URL],
        liveness: (Target, [OpenHandleHolder]?) -> LiveCheckResult,
        finish: (Session, Target, LiveCheckResult) throws -> Plan
    ) async -> [PlannedSession] {
        let located = sessions.map { session in Result { try locate(session) } }
        let groups = located.compactMap { try? $0.get() }.map(files)
        var holders = await openHandleHolders(of: groups, checker: checker).makeIterator()
        return zip(sessions, located).map { session, target in
            PlannedSession(session: session, result: target.flatMap { target in
                let live = liveness(target, holders.next() ?? nil)
                return Result { try finish(session, target, live) }
            })
        }
    }

    /// Live checks for a batch, the way `plans` asks the open-file question once.
    static func liveChecks<Target>(
        for sessions: [Session], checker: any OpenHandleChecker,
        locate: (Session) throws -> Target, files: (Target) -> [URL],
        liveness: (Target, [OpenHandleHolder]?) -> LiveCheckResult
    ) async -> [Result<LiveCheckResult, any Error>] {
        let located = sessions.map { session in Result { try locate(session) } }
        let groups = located.compactMap { try? $0.get() }.map(files)
        var holders = await openHandleHolders(of: groups, checker: checker).makeIterator()
        return located.map { target in target.map { liveness($0, holders.next() ?? nil) } }
    }
}
