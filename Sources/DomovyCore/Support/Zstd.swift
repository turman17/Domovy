import CZstd
import Foundation

/// Why Domovy could not read zstd data, in words the UI can show.
public enum ZstdError: Error, Equatable, LocalizedError {
    /// The file could not be opened or read.
    case unreadable(reason: String)
    /// The data is not valid zstd (the decoder's own error name).
    case corrupt(reason: String)
    /// The data ended in the middle of a frame.
    case truncated
    /// It decompresses to more than Domovy is willing to read.
    case tooLarge(limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "Domovy could not read the compressed file: \(reason)"
        case .corrupt(let reason): "The compressed data is damaged (\(reason))."
        case .truncated: "The compressed data ends too early; the file may still be being written."
        case .tooLarge(let limit): "It decompresses to more than \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)), more than Domovy reads."
        }
    }
}

/// Streaming zstd decompression over the vendored libzstd (decompression only). Memory stays
/// bounded: input is read in the decoder's preferred chunks, output goes into the caller's
/// buffer, and the decoder refuses frames whose window exceeds zstd's default limit (128 MB).
/// Output beyond `limit` bytes throws `.tooLarge`. Decompressed bytes may hold transcript text:
/// nothing here logs them.
final class ZstdReader {
    /// Everything a whole-file read (the secret scan) may decompress.
    static let defaultLimit: Int64 = 4 << 30

    private let source: (Int) throws -> Data
    private let onClose: () -> Void
    private let context: OpaquePointer
    private let limit: Int64
    private var input: [UInt8] = []
    private var inputPosition = 0
    private var sourceEnded = false
    private var sawInput = false
    /// The last call that made progress ended a frame.
    private var frameEnded = true
    private var produced: Int64 = 0

    /// Reads from `source(count)`, which returns at most `count` bytes and empty data at the end.
    init(limit: Int64 = ZstdReader.defaultLimit, source: @escaping (Int) throws -> Data, onClose: @escaping () -> Void = {}) throws(ZstdError) {
        guard let context = ZSTD_createDCtx() else { throw .corrupt(reason: "out of memory") }
        self.context = context
        self.limit = limit
        self.source = source
        self.onClose = onClose
    }

    convenience init(url: URL, limit: Int64 = ZstdReader.defaultLimit) throws(ZstdError) {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw .unreadable(reason: error.localizedDescription)
        }
        try self.init(limit: limit, source: { try handle.read(upToCount: $0) ?? Data() }, onClose: { try? handle.close() })
    }

    deinit {
        ZSTD_freeDCtx(context)
        onClose()
    }

    func close() {
        onClose()
    }

    /// Up to `count` decompressed bytes; empty data at the end of the stream.
    func read(upToCount count: Int) throws(ZstdError) -> Data {
        guard count > 0 else { return Data() }
        var output = Data(count: count)
        var outputPosition = 0
        while outputPosition < count {
            if inputPosition == input.count, !sourceEnded {
                let chunk: Data
                do {
                    chunk = try source(ZSTD_DStreamInSize())
                } catch {
                    throw .unreadable(reason: error.localizedDescription)
                }
                if chunk.isEmpty {
                    sourceEnded = true
                } else {
                    input = [UInt8](chunk)
                    inputPosition = 0
                    sawInput = true
                }
            }
            let before = (inputPosition, outputPosition)
            let result = input.withUnsafeBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    var inBuffer = ZSTD_inBuffer(src: inputBytes.baseAddress, size: inputBytes.count, pos: inputPosition)
                    var outBuffer = ZSTD_outBuffer(dst: outputBytes.baseAddress, size: count, pos: outputPosition)
                    let code = ZSTD_decompressStream(context, &outBuffer, &inBuffer)
                    inputPosition = inBuffer.pos
                    outputPosition = outBuffer.pos
                    return code
                }
            }
            if ZSTD_isError(result) != 0 {
                throw .corrupt(reason: String(cString: ZSTD_getErrorName(result)))
            }
            produced += Int64(outputPosition - before.1)
            if produced > limit { throw .tooLarge(limit: limit) }
            let progressed = (inputPosition, outputPosition) != before
            if progressed { frameEnded = result == 0 }
            guard !progressed else { continue }
            if sourceEnded {
                if !sawInput || !frameEnded { throw .truncated }
                break
            }
            if inputPosition < input.count { throw .corrupt(reason: "the decoder made no progress") }
        }
        return output.prefix(outputPosition)
    }

    /// Reads to the end, at most `limit` bytes.
    func readAll() throws(ZstdError) -> Data {
        var result = Data()
        while true {
            let chunk = try read(upToCount: 1 << 20)
            if chunk.isEmpty { return result }
            result.append(chunk)
        }
    }
}

enum Zstd {
    /// zstd frames start with these bytes (little-endian 0xFD2FB528).
    static let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]

    /// Decompresses an in-memory blob (a database row). Refuses a frame that declares more
    /// than `limit` bytes before decoding anything.
    static func decompress(_ data: Data, limit: Int64) throws(ZstdError) -> Data {
        let declared = data.withUnsafeBytes { ZSTD_getFrameContentSize($0.baseAddress, $0.count) }
        // UInt64.max - 1 is ZSTD_CONTENTSIZE_ERROR, UInt64.max ZSTD_CONTENTSIZE_UNKNOWN.
        if declared == UInt64.max - 1 { throw .corrupt(reason: "not a zstd frame") }
        if declared != UInt64.max, declared > UInt64(limit) { throw .tooLarge(limit: limit) }
        var remaining = data
        let reader = try ZstdReader(limit: limit, source: { count in
            let chunk = remaining.prefix(count)
            remaining = remaining.dropFirst(chunk.count)
            return Data(chunk)
        })
        return try reader.readAll()
    }

    /// The first `maxBytes` bytes of a file, decompressing it when its name ends in `.zst`.
    static func prefix(of url: URL, maxBytes: Int) throws -> Data {
        if url.lastPathComponent.hasSuffix(".zst") {
            return try ZstdReader(url: url).read(upToCount: maxBytes)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: maxBytes) ?? Data()
    }
}
