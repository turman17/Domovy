import Foundation

/// Reads a file line by line in fixed chunks, so memory stays bounded however large the file
/// is. A line longer than `maxLineBytes` comes out in overlapping pieces marked `isPartial`.
/// A `.zst` file is read decompressed; offsets are then positions in the decompressed text.
struct LineStream {
    struct Line {
        /// One-based line number.
        let number: Int
        /// Offset of `bytes.first` in the file.
        let offset: Int64
        let bytes: Data
        /// A piece of a line too long to hold at once.
        let isPartial: Bool
    }

    static let chunkSize = 1 << 20
    /// Pieces of a long line overlap by this much, so a secret on a piece boundary is still seen.
    static let overlap = 4096

    private enum Source {
        case file(FileHandle)
        case zstd(ZstdReader)
    }

    private let source: Source
    private let maxLineBytes: Int
    /// Read but not yet returned bytes are `buffer[head...]`; consumed bytes are dropped only
    /// when the next chunk is read, so returning a line never moves the rest.
    private var buffer: [UInt8] = []
    private var head = 0
    private var bufferOffset: Int64 = 0
    /// Where to look for the next newline, relative to `head`.
    private var searchFrom = 0
    private var atEnd = false
    private var lineNumber = 1
    private var continuingLongLine = false

    private let chunkSize: Int

    init(url: URL, maxLineBytes: Int, chunkSize: Int = Self.chunkSize) throws {
        source = url.lastPathComponent.hasSuffix(".zst")
            ? .zstd(try ZstdReader(url: url))
            : .file(try FileHandle(forReadingFrom: url))
        self.chunkSize = chunkSize
        self.maxLineBytes = max(maxLineBytes, Self.overlap * 2)
    }

    func close() {
        switch source {
        case .file(let handle): try? handle.close()
        case .zstd(let reader): reader.close()
        }
    }

    private func read() throws -> Data {
        switch source {
        case .file(let handle): try handle.read(upToCount: chunkSize) ?? Data()
        case .zstd(let reader): try reader.read(upToCount: chunkSize)
        }
    }

    mutating func next() throws -> Line? {
        while true {
            let pending = buffer.count - head
            if let newline = newlineIndex(), newline <= maxLineBytes {
                let line = Line(number: lineNumber, offset: bufferOffset, bytes: Data(buffer[head..<(head + newline)]), isPartial: continuingLongLine)
                drop(newline + 1)
                lineNumber += 1
                continuingLongLine = false
                return line
            }
            if pending >= maxLineBytes {
                let piece = Line(number: lineNumber, offset: bufferOffset, bytes: Data(buffer[head..<(head + maxLineBytes)]), isPartial: true)
                drop(maxLineBytes - Self.overlap)
                continuingLongLine = true
                return piece
            }
            searchFrom = pending
            if atEnd {
                guard pending > 0 else { return nil }
                let line = Line(number: lineNumber, offset: bufferOffset, bytes: Data(buffer[head...]), isPartial: continuingLongLine)
                drop(pending)
                return line
            }
            let chunk = try read()
            if chunk.isEmpty {
                atEnd = true
            } else {
                buffer.removeSubrange(0..<head)
                head = 0
                buffer.append(contentsOf: chunk)
            }
        }
    }

    /// The first newline at or after `searchFrom`, relative to `head`.
    private func newlineIndex() -> Int? {
        let from = head + searchFrom
        guard from < buffer.count else { return nil }
        return buffer.withUnsafeBufferPointer { pointer -> Int? in
            guard let base = pointer.baseAddress,
                  let found = memchr(base + from, Int32(UInt8(ascii: "\n")), pointer.count - from) else { return nil }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self)) - head
        }
    }

    private mutating func drop(_ count: Int) {
        head += count
        bufferOffset += Int64(count)
        searchFrom = 0
    }
}
