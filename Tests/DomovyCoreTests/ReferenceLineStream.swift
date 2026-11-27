@testable import DomovyCore
import Foundation

/// `LineStream` as it was before it stopped copying the buffer after every line, kept as the
/// reference the current one must agree with.
/// A line longer than `maxLineBytes` comes out in overlapping pieces marked `isPartial`.
struct ReferenceLineStream {
    struct Line {
        /// One-based line number.
        let number: Int
        /// Offset of `bytes.first` in the file.
        let offset: Int64
        let bytes: Data
        /// A piece of a line too long to hold at once.
        let isPartial: Bool
    }

    static let chunkSize = LineStream.chunkSize
    /// Pieces of a long line overlap by this much, so a secret on a piece boundary is still seen.
    static let overlap = LineStream.overlap

    private let handle: FileHandle
    private let maxLineBytes: Int
    private var buffer = Data()
    private var bufferOffset: Int64 = 0
    private var searchFrom = 0
    private var atEnd = false
    private var lineNumber = 1
    private var continuingLongLine = false

    private let chunkSize: Int

    init(url: URL, maxLineBytes: Int, chunkSize: Int = Self.chunkSize) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.chunkSize = chunkSize
        self.maxLineBytes = max(maxLineBytes, Self.overlap * 2)
    }

    func close() {
        try? handle.close()
    }

    mutating func next() throws -> Line? {
        while true {
            if let newline = buffer[searchFrom...].firstIndex(of: UInt8(ascii: "\n")), newline <= maxLineBytes {
                let line = Line(number: lineNumber, offset: bufferOffset, bytes: Data(buffer[..<newline]), isPartial: continuingLongLine)
                drop(newline + 1)
                lineNumber += 1
                continuingLongLine = false
                return line
            }
            if buffer.count >= maxLineBytes {
                let piece = Line(number: lineNumber, offset: bufferOffset, bytes: Data(buffer.prefix(maxLineBytes)), isPartial: true)
                drop(maxLineBytes - Self.overlap)
                continuingLongLine = true
                return piece
            }
            searchFrom = buffer.count
            if atEnd {
                guard !buffer.isEmpty else { return nil }
                let line = Line(number: lineNumber, offset: bufferOffset, bytes: buffer, isPartial: continuingLongLine)
                drop(buffer.count)
                return line
            }
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { atEnd = true } else { buffer.append(chunk) }
        }
    }

    private mutating func drop(_ count: Int) {
        buffer = Data(buffer.dropFirst(count))
        bufferOffset += Int64(count)
        searchFrom = 0
    }
}
