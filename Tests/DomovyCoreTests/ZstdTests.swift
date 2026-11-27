@testable import DomovyCore
import CryptoKit
import Foundation
import Testing

/// The vendored zstd decoder through Domovy's wrapper. Fixtures were made with the zstd CLI
/// (`Tests/Fixtures/zstd/`, Codex's rollout under `codex/0.169`); nothing here compresses.
@Suite("Zstd")
struct ZstdTests {
    static let twoFrames = FixtureHome.fixturesRoot.appendingPathComponent("zstd/two-frames.txt.zst")
    /// SHA-256 of the decompressed `two-frames.txt.zst`: 17 bytes of frame one, then
    /// "line 1"…"line 20000" in a second frame that does not declare its size.
    static let twoFramesSHA = "c4c6490f9059ad8b1c2761c595f23fb2f363bf911cf82c96e7abc3472c52748d"

    private func sha(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-zstd-\(UUID().uuidString).zst")
        try data.write(to: url)
        return url
    }

    @Test("streams several frames in small reads, with and without a declared size")
    func streams() throws {
        let reader = try ZstdReader(url: Self.twoFrames)
        var output = Data()
        while true {
            let chunk = try reader.read(upToCount: 777)
            if chunk.isEmpty { break }
            #expect(chunk.count <= 777)
            output.append(chunk)
        }
        #expect(output.count == 208_911)
        #expect(sha(output) == Self.twoFramesSHA)
        #expect(String(decoding: output.prefix(17), as: UTF8.self) == "first frame line\n")
    }

    @Test("in-memory decompress matches the stream; a declared size over the limit is refused up front")
    func inMemory() throws {
        let compressed = try Data(contentsOf: Self.twoFrames)
        #expect(sha(try Zstd.decompress(compressed, limit: 1 << 20)) == Self.twoFramesSHA)
        // The first frame declares 17 bytes, so even a tiny limit fails before decoding.
        #expect(throws: ZstdError.tooLarge(limit: 8)) { try Zstd.decompress(compressed, limit: 8) }
        // The second frame declares nothing: the stream stops once it passes the limit.
        #expect(throws: ZstdError.tooLarge(limit: 100_000)) { try Zstd.decompress(compressed, limit: 100_000) }
    }

    @Test("truncated, damaged and empty data are refused with a typed reason")
    func refuses() throws {
        let compressed = try Data(contentsOf: Self.twoFrames)
        let cut = try temporaryFile(compressed.prefix(compressed.count - 20))
        defer { try? FileManager.default.removeItem(at: cut) }
        #expect(throws: ZstdError.truncated) { try ZstdReader(url: cut).readAll() }

        #expect(throws: ZstdError.self) { try Zstd.decompress(Data("not zstd at all".utf8), limit: 1024) }
        // Garbage after the magic number never decodes (its header may claim any size).
        #expect(throws: ZstdError.self) { try Zstd.decompress(Data(Zstd.magic + Array("garbage after magic".utf8)), limit: 1024) }
        #expect(ZstdError.corrupt(reason: "x").localizedDescription.contains("damaged"))

        let empty = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(throws: ZstdError.truncated) { try ZstdReader(url: empty).readAll() }
        #expect(throws: ZstdError.self) { try ZstdReader(url: URL(fileURLWithPath: "/nonexistent/domovy.zst")) }
    }

    @Test("line stream over a .zst reads the decompressed lines")
    func lineStream() throws {
        var stream = try LineStream(url: Self.twoFrames, maxLineBytes: 1 << 16, chunkSize: 4096)
        defer { stream.close() }
        var count = 0
        var last: LineStream.Line?
        while let line = try stream.next() {
            count += 1
            last = line
        }
        #expect(count == 20_001)
        #expect(last.map { String(decoding: $0.bytes, as: UTF8.self) } == "line 20000")
    }

    @Test("Codex: the header of a .jsonl.zst rollout is read decompressed")
    func codexHeader() throws {
        let url = FixtureHome.fixturesRoot.appendingPathComponent(
            "codex/0.169/sessions/2026/10/30/rollout-2026-10-30T14-05-00-01a1f033-3333-7333-8333-333333333333.jsonl.zst")
        let header = CodexRollout.readHeader(of: url)
        #expect(header.cwd == "/Users/dev/code/ledger")
        #expect(header.title == "Migrate cron jobs to the queue")
    }
}
