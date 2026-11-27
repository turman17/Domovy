import DomovyCore
import Foundation
import Testing

@Suite("Transcript reader")
struct TranscriptReaderTests {
    typealias IDs = FixtureHome.ClaudeCode

    @Test("renders user and assistant turns, tool calls as one-line summaries, skips tool results")
    func messages() async throws {
        let fixture = try FixtureHome()
        let adapter = fixture.adapter()
        let transcript = try await adapter.transcript(of: adapter.session(matching: IDs.idle), limit: 50)
        #expect(!transcript.isTruncated)

        let roles = transcript.messages.map(\.role)
        #expect(roles == [.user, .assistant, .user, .assistant, .assistant, .assistant])
        #expect(transcript.messages[0].blocks == [.text("Add rate limiting to the orbit API")])
        #expect(transcript.messages[1].blocks == [.text("I will add a token bucket middleware.")])
        // Paths are relative to the session's cwd; Bash prefers its description.
        #expect(transcript.messages[3].blocks == [.toolCall("Edit src/middleware/rate_limit.py")])
        #expect(transcript.messages[4].blocks == [.toolCall("Bash Run the rate limit tests")])
        #expect(transcript.messages[5].blocks.first == .text("Done. The middleware allows 100 requests per minute per client and the tests pass."))
        #expect(transcript.messages[0].id == "0c1b4b2e-0000-4000-8000-000000000001")
        #expect(transcript.messages[0].timestamp != nil)
    }

    @Test("skips slash-command echoes and meta records")
    func skipsEchoes() async throws {
        let fixture = try FixtureHome()
        let adapter = fixture.adapter()
        let transcript = try await adapter.transcript(of: adapter.session(matching: IDs.live), limit: 50)
        #expect(transcript.messages.map(\.blocks) == [[.text("Refactor the billing module into smaller services")]])
    }

    @Test("stops after the message limit and after the byte budget")
    func bounded() async throws {
        let fixture = try FixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)

        let two = try await adapter.transcript(of: session, limit: 2)
        #expect(two.messages.count == 2)
        #expect(two.isTruncated)

        let tiny = try TranscriptReader(maxMessages: 100, maxBytes: 400).read(session.transcriptURL)
        #expect(tiny.isTruncated)
        #expect(tiny.messages.count == 1)

        let missing = session.transcriptURL.deletingLastPathComponent().appendingPathComponent("nope.jsonl")
        #expect(throws: AdapterError.self) { try TranscriptReader().read(missing) }
    }

    @Test("pages from the end: newest messages first, older pages until the start, same messages in order")
    func pagesFromTheEnd() async throws {
        let fixture = try FixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        let all = try await adapter.transcript(of: session, limit: 50).messages

        let newest = try await adapter.transcriptPage(of: session, limit: 4, before: nil, masking: [])
        #expect(newest.messages == Array(all.suffix(4)))
        let cursor = try #require(newest.olderCursor)

        let older = try await adapter.transcriptPage(of: session, limit: 4, before: cursor, masking: [])
        #expect(older.messages == Array(all.prefix(all.count - 4)))
        #expect(older.olderCursor == nil)

        let whole = try await adapter.transcriptPage(of: session, limit: 50, before: nil, masking: [])
        #expect(whole.messages == all)
        #expect(whole.olderCursor == nil)
    }

    @Test("a large transcript opens at its last message, past the forward byte budget")
    func largeTail() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("long.jsonl")
        let filler = String(repeating: "x", count: 2_000)
        var text = ""
        for index in 0..<3_000 {
            text += #"{"type":"user","uuid":"m\#(index)","message":{"role":"user","content":"\#(index) \#(filler)"}}"# + "\n"
        }
        try Data(text.utf8).write(to: file)

        let newest = try TranscriptReader.readPage(file, limit: 200, before: nil)
        #expect(newest.messages.count == 200)
        #expect(newest.messages.last?.id == "m2999")
        #expect(newest.messages.first?.id == "m2800")
        let older = try TranscriptReader.readPage(file, limit: 200, before: try #require(newest.olderCursor))
        #expect(older.messages.last?.id == "m2799")
    }
}
