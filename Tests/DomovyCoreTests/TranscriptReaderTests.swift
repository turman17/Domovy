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
}
