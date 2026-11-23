import Compression
import Foundation

public enum CompressionError: Error, LocalizedError, Sendable {
    case notRegularFile(URL)
    case changedSincePlan(URL)
    case toolFailed(URL, status: Int32)
    case verificationFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .notRegularFile(let url):
            "\(url.lastPathComponent) is not a regular file, so it was left alone."
        case .changedSincePlan(let url):
            "\(url.lastPathComponent) changed after the plan was made, so it was left alone. Something may be writing to this session."
        case .toolFailed(let url, let status):
            "The system copy tool (ditto) failed on \(url.lastPathComponent) with status \(status). The original is unchanged."
        case .verificationFailed(let url):
            "The rewritten copy of \(url.lastPathComponent) did not match the original byte for byte. The original is unchanged."
        }
    }
}

/// APFS transparent compression (decmpfs) of single files, through the system `ditto`.
///
/// A file is rewritten into a temporary sibling folder by piping `ditto -c` into
/// `ditto -x --hfsCompression` (a plain `ditto --hfsCompression` clones on APFS and does
/// not compress), checked byte for byte, given back its exact mtime and permissions, and
/// renamed over the original. The parent folder's mtime is put back too. Readers see the
/// same bytes; a later write by the agent decompresses the file transparently.
enum APFSCompression {
    enum Outcome: Equatable, Sendable {
        case rewritten
        /// Nothing changed; the reason is user-explainable.
        case skipped(String)
    }

    /// `ditto` leaves files of 16 KiB or less uncompressed (measured on macOS 27), so plans skip them.
    static let minimumUsefulSize: Int64 = 16 * 1024

    static func isCompressed(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_flags & UInt32(UF_COMPRESSED) != 0
    }

    static func isRegularFile(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFREG
    }

    /// Bytes the file occupies on disk (allocated blocks), as opposed to its logical size.
    /// The file itself, or every regular file below a folder. Symlinks are never followed.
    static func regularFiles(at url: URL) -> [URL] {
        guard FileSystem.isDirectory(url) else { return isRegularFile(url) ? [url] : [] }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: []) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .map(\.standardizedFileURL)
            .filter { isRegularFile($0) }
            .sorted { $0.path < $1.path }
    }

    static func allocatedBytes(of url: URL) -> Int64 {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return 0 }
        return Int64(info.st_blocks) * 512
    }

    // MARK: Compress and decompress

    /// Compresses `url` in place. `expected` is the mtime seen at plan time; a file that
    /// changed since is skipped by throwing `changedSincePlan`.
    static func compress(_ url: URL, expected: FileTime?) throws -> Outcome {
        guard isRegularFile(url) else { throw CompressionError.notRegularFile(url) }
        if isCompressed(url) { return .skipped("already compressed") }
        if let expected, FileSystem.modificationTime(of: url) != expected { throw CompressionError.changedSincePlan(url) }
        return try rewrite(url, compressed: true)
    }

    /// Puts a compressed file back in plain form, keeping mtime and permissions.
    static func decompress(_ url: URL) throws -> Outcome {
        guard isRegularFile(url) else { throw CompressionError.notRegularFile(url) }
        guard isCompressed(url) else { return .skipped("not compressed (the agent may have written to it since)") }
        return try rewrite(url, compressed: false)
    }

    private static func rewrite(_ url: URL, compressed: Bool) throws -> Outcome {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        let parentTime = FileSystem.modificationTime(of: parent)
        let mtime = FileSystem.modificationTime(of: url)
        let permissions = FileSystem.posixPermissions(of: url)
        let sizeBefore = FileSystem.size(of: url)

        // Same folder, so the final rename is atomic and stays on one volume. No `.jsonl` in
        // the name, so a leftover never looks like a transcript to an agent.
        let staging = parent.appendingPathComponent(".domovy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer {
            try? fm.removeItem(at: staging)
            if let parentTime { try? FileSystem.setModificationTime(parentTime, of: parent) }
        }

        try runDittoPipe(source: url, into: staging, compress: compressed)
        let copy = staging.appendingPathComponent(url.lastPathComponent)
        guard isRegularFile(copy), try sameContents(url, copy) else { throw CompressionError.verificationFailed(url) }
        if compressed, !isCompressed(copy) { return .skipped("APFS found nothing to gain") }

        if let permissions { try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: copy.path) }
        if let mtime { try FileSystem.setModificationTime(mtime, of: copy) }

        // Last look before the swap: an agent that wrote meanwhile wins and we back off.
        guard FileSystem.modificationTime(of: url) == mtime, FileSystem.size(of: url) == sizeBefore else {
            throw CompressionError.changedSincePlan(url)
        }
        guard rename(copy.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return .rewritten
    }

    /// `ditto -c <file> - | ditto -x [--hfsCompression|--nohfsCompression] - <folder>`, no shell.
    private static func runDittoPipe(source: URL, into folder: URL, compress: Bool) throws {
        let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
        let pipe = Pipe()
        let archive = Process()
        archive.executableURL = ditto
        archive.arguments = ["-c", source.path, "-"]
        archive.standardOutput = pipe
        archive.standardError = FileHandle.nullDevice
        let extract = Process()
        extract.executableURL = ditto
        extract.arguments = ["-x", compress ? "--hfsCompression" : "--nohfsCompression", "-", folder.path]
        extract.standardInput = pipe
        extract.standardError = FileHandle.nullDevice

        try extract.run()
        do { try archive.run() } catch {
            extract.terminate()
            throw error
        }
        archive.waitUntilExit()
        extract.waitUntilExit()
        if archive.terminationStatus != 0 { throw CompressionError.toolFailed(source, status: archive.terminationStatus) }
        if extract.terminationStatus != 0 { throw CompressionError.toolFailed(source, status: extract.terminationStatus) }
    }

    private static func sameContents(_ a: URL, _ b: URL) throws -> Bool {
        let ha = try FileHandle(forReadingFrom: a)
        let hb = try FileHandle(forReadingFrom: b)
        defer {
            try? ha.close()
            try? hb.close()
        }
        while true {
            let chunkA = try ha.read(upToCount: 1 << 20) ?? Data()
            let chunkB = try hb.read(upToCount: 1 << 20) ?? Data()
            if chunkA != chunkB { return false }
            if chunkA.isEmpty { return true }
        }
    }

    // MARK: Estimate

    /// Rough on-disk size after compression: LZFSE over 64 KiB chunks like decmpfs, rounded
    /// up to 4 KiB blocks. Large files are sampled from the first 16 MiB.
    static func estimatedCompressedBytes(of url: URL) -> Int64 {
        let size = FileSystem.size(of: url)
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let chunk = 64 * 1024
        let sampleLimit: Int64 = 16 * 1024 * 1024
        var read: Int64 = 0
        var packed: Int64 = 0
        var output = [UInt8](repeating: 0, count: chunk + 4096)
        while read < min(size, sampleLimit), let data = try? handle.read(upToCount: chunk), !data.isEmpty {
            let encoded = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(&output, output.count, base, data.count, nil, COMPRESSION_LZFSE)
            }
            packed += Int64(encoded == 0 || encoded >= data.count ? data.count : encoded)
            read += Int64(data.count)
        }
        guard read > 0 else { return size }
        let projected = Double(packed) / Double(read) * Double(size)
        let blocks = (Int64(projected.rounded(.up)) + 4095) / 4096
        return min(blocks * 4096, max(allocatedBytes(of: url), size))
    }
}
