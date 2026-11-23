@testable import DomovyCore
import Foundation
import Testing

@Suite("Secrets in history.jsonl and masked previews")
struct HistorySecretsTests {
    typealias IDs = FixtureHome.ClaudeCode

    /// One history line for `session` with `text` as the typed prompt, as Claude Code writes it.
    static func historyLine(_ text: String, session: String) -> String {
        let object: [String: Any] = ["display": text, "pastedContents": [String: Any](), "timestamp": 1763629300000,
                                     "project": "/Users/dev/code/orbit-api", "sessionId": session]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Appends a secret prompt for the idle session and one for the live session.
    private func fixture() throws -> (FixtureHome, URL) {
        let fixture = try FixtureHome()
        let history = fixture.claudeDirectory.appendingPathComponent("history.jsonl")
        let handle = try FileHandle(forWritingTo: history)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((Self.historyLine("use \(SecretSamples.openAI) for the eval", session: IDs.idle) + "\n").utf8))
        try handle.write(contentsOf: Data((Self.historyLine("token \(SecretSamples.github)", session: IDs.live) + "\n").utf8))
        try handle.close()
        try FileSystem.setModificationTime(FileTime(seconds: 1_795_000_000, nanoseconds: 42), of: history)
        return (fixture, history)
    }

    @Test("the scan reads only the session's own history lines")
    func scan() async throws {
        let (fixture, history) = try fixture()
        let adapter = fixture.adapter()
        let report = try await SecretScanner().scan(try await adapter.session(matching: IDs.idle), adapter: adapter)
        let found = report.findings.filter { $0.file == history }
        #expect(found.count == 1)
        #expect(found.first?.ruleID == "openai-key")
        #expect(found.first?.sessionID == IDs.idle)
        #expect(found.first?.isRedactable == true)
        #expect(!report.findings.contains { $0.ruleID == "github-token" })
    }

    @Test("line-level redaction of history.jsonl keeps other lines and mtime; undo keeps lines added since")
    func redactAndUndo() async throws {
        let (fixture, history) = try fixture()
        let before = try String(contentsOf: history, encoding: .utf8)
        let mtime = try #require(FileSystem.modificationTime(of: history))
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        let report = try await SecretScanner().scan(session, adapter: adapter)
        let plan = try await RedactionPlanner.plan(for: session, findings: report.findings, adapter: adapter)
        let item = try #require(plan.redactions.first { $0.file == history })
        #expect(item.isLineLevel)
        #expect(plan.remarks.contains { $0.contains("Only this session's lines") })

        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        let after = try String(contentsOf: history, encoding: .utf8)
        #expect(!after.contains(SecretSamples.openAI))
        #expect(after.contains("[REDACTED:openai-key]"))
        #expect(after.contains(SecretSamples.github), "another session's line is not touched")
        #expect(after.split(separator: "\n").count == before.split(separator: "\n").count)
        #expect(FileSystem.modificationTime(of: history) == mtime)
        for line in after.split(separator: "\n") { #expect(JSONText.isValidJSON(Data(line.utf8))) }

        // Claude Code appends a prompt before the user undoes.
        let appended = Self.historyLine("a later prompt", session: IDs.live)
        try Data((after + appended + "\n").utf8).write(to: history)
        _ = try executor.undo(entry)
        let restored = try String(contentsOf: history, encoding: .utf8)
        #expect(restored == before + appended + "\n")
    }

    @Test("a history line that moved since the scan is not rewritten")
    func movedLineRefused() async throws {
        let (fixture, history) = try fixture()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        let report = try await SecretScanner().scan(session, adapter: adapter)
        let plan = try await RedactionPlanner.plan(for: session, findings: report.findings.filter { $0.file == history }, adapter: adapter)
        // Something removed the first line meanwhile: every offset shifts.
        let text = try String(contentsOf: history, encoding: .utf8)
        try Data(text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n").utf8).write(to: history)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        #expect(try String(contentsOf: history, encoding: .utf8).contains(SecretSamples.openAI))
    }

    // MARK: Masking

    @Test("the preview shows masks, never the value; a line that cannot be masked is hidden")
    func masking() async throws {
        let fixture = try FixtureHome()
        let url = fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api")
        var text = try String(contentsOf: url, encoding: .utf8)
        text += SecretSamples.claudeLine("deploy with \(SecretSamples.anthropic) please", session: IDs.idle) + "\n"
        text += "{\"type\":\"user\",\"broken\":\"\(SecretSamples.aws)\n"
        try Data(text.utf8).write(to: url)
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        let report = try await SecretScanner().scan(session, adapter: adapter)
        let finding = try #require(report.findings.first { $0.ruleID == "anthropic-key" })

        let plain = try await adapter.transcript(of: session, limit: 200)
        #expect(Self.allText(plain).contains(SecretSamples.anthropic))

        let masked = try await adapter.transcript(of: session, limit: 200, masking: report.findings)
        let shown = Self.allText(masked)
        #expect(!shown.contains(SecretSamples.anthropic))
        #expect(shown.contains("deploy with \(finding.preview) please"))
        #expect(finding.preview.hasPrefix("sk-ant-"))
        #expect(plain.messages.count == masked.messages.count)
        // The broken line is not JSON either way; it is hidden rather than shown unmasked.
        #expect(masked.hiddenLineCount == 1)
    }

    @Test("mask helper: masks inside JSON strings, hides a line that changed length")
    func maskHelper() throws {
        let line = Data(SecretSamples.claudeLine("key \(SecretSamples.github) end").utf8)
        let start = try #require(line.range(of: Data(SecretSamples.github.utf8)))
        let finding = SecretFinding(
            sessionID: IDs.idle, agent: .claudeCode, file: URL(fileURLWithPath: "/tmp/x.jsonl"), line: 1,
            ruleID: "github-token", preview: "ghp_…\"0000\\", byteRange: Int64(start.lowerBound)..<Int64(start.upperBound),
            lineOffset: 0, lineLength: line.count, redaction: .inJSONString
        )
        let mask = TranscriptMask(findings: [finding], file: URL(fileURLWithPath: "/tmp/x.jsonl"))
        let masked = try #require(mask.apply(line, at: 0))
        let text = String(decoding: masked, as: UTF8.self)
        #expect(!text.contains(SecretSamples.github))
        #expect(text.contains("ghp_\u{2026}0000"), "quotes and backslashes are dropped from the mask")
        #expect(JSONText.isValidJSON(masked))
        #expect(mask.apply(line + Data("x".utf8), at: 0) == nil)
        #expect(mask.apply(line, at: 99) == line, "other lines pass through")
        #expect(TranscriptMask(findings: [finding], file: URL(fileURLWithPath: "/tmp/other.jsonl")).isEmpty)
    }

    static func allText(_ transcript: Transcript) -> String {
        transcript.messages.flatMap(\.blocks).map { block in
            switch block {
            case .text(let text): text
            case .toolCall(let summary): summary
            }
        }.joined(separator: "\n")
    }
}
