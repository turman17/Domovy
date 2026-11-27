import Foundation

/// Reads a JSON-lines transcript from the end, so a reader can open at the newest message and
/// load older pages on demand. Cursors are byte offsets of line starts, so a page stays put
/// while a live session appends to the file. Content is returned and never logged.
enum TranscriptTail {
    struct Line {
        /// Byte offset of the line in the file.
        let offset: Int64
        let data: Data
    }

    /// A message and the offset of the line it starts at.
    typealias Parsed = (offset: Int64, message: TranscriptMessage)

    static let firstWindow = 512 * 1024
    /// The most one page reads; a window grows up to it while it holds too few messages.
    static let maxWindow = 16 * 1024 * 1024

    /// The newest `limit` messages that start before `cursor`. `parse` turns masked lines,
    /// oldest first, into messages. `contents` stands in for the file when it had to be
    /// decompressed; `contentsCut` says it is not the whole file.
    static func page(of file: URL, limit: Int, before cursor: TranscriptCursor?, masking findings: [SecretFinding],
                     contents: Data? = nil, contentsCut: Bool = false, parse: ([Line]) -> [Parsed]) throws -> Transcript {
        let source = try Source(file: file, contents: contents)
        let mask = TranscriptMask(findings: findings, file: file)
        let end = min(max(0, cursor?.position ?? source.size), source.size)
        var window = Int64(firstWindow)
        while true {
            let start = max(0, end - window)
            let chunk = source.read(start..<end)
            var lines: [Line] = []
            var hidden = 0
            var segments = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            // The first segment of a window that starts mid-file may be part of a line.
            if start > 0, !segments.isEmpty { segments.removeFirst() }
            for raw in segments {
                let offset = start + Int64(raw.startIndex - chunk.startIndex)
                guard let line = mask.apply(Data(raw), at: offset) else {
                    hidden += 1
                    continue
                }
                lines.append(Line(offset: offset, data: line))
            }
            let parsed = parse(lines)
            let reachedStart = start == 0
            if parsed.count < limit, !reachedStart, window < Int64(maxWindow) {
                window *= 4
                continue
            }
            let kept = parsed.suffix(max(0, limit))
            let older: TranscriptCursor?
            if parsed.count > kept.count, let first = kept.first {
                older = TranscriptCursor(first.offset)
            } else if !reachedStart, let firstLine = segments.first {
                older = TranscriptCursor(start + Int64(firstLine.startIndex - chunk.startIndex))
            } else {
                // At the start, or one line larger than a page: nothing older can be shown.
                older = nil
            }
            return Transcript(
                messages: kept.map(\.message),
                isTruncated: cursor == nil && contentsCut,
                hiddenLineCount: hidden,
                olderCursor: older
            )
        }
    }

    /// The file, or its decompressed contents.
    private struct Source {
        let size: Int64
        private let handle: FileHandle?
        private let contents: Data?

        init(file: URL, contents: Data?) throws {
            self.contents = contents
            if let contents {
                handle = nil
                size = Int64(contents.count)
                return
            }
            do {
                let handle = try FileHandle(forReadingFrom: file)
                self.handle = handle
                size = Int64(try handle.seekToEnd())
            } catch {
                throw AdapterError.unreadable(file, reason: error.localizedDescription)
            }
        }

        func read(_ range: Range<Int64>) -> Data {
            guard !range.isEmpty else { return Data() }
            if let contents { return contents.subdata(in: Int(range.lowerBound)..<Int(range.upperBound)) }
            guard let handle, (try? handle.seek(toOffset: UInt64(range.lowerBound))) != nil else { return Data() }
            return (try? handle.read(upToCount: Int(range.count))) ?? Data()
        }
    }
}
