@testable import DomovyCore
import Foundation
import Testing

@Suite("Redaction and purge")
struct RedactionTests {
    typealias IDs = FixtureHome.ClaudeCode
    static let flagged = "eeeeeeee-5555-4555-8555-555555555555"
    static let project = "-Users-dev-code-orbit-api"

    /// A clean line, every sample on its own line, a broken line and a final clean line.
    static func transcript() -> String {
        var lines = [SecretSamples.claudeLine("Set up the billing service", session: flagged)]
        lines += SecretSamples.cases.map { SecretSamples.claudeLine($0.text, session: flagged) }
        lines.append("{\"type\":\"user\",\"broken\":\"\(SecretSamples.aws)")
        lines.append(SecretSamples.claudeLine("Thanks, that works", session: flagged))
        return lines.joined(separator: "\n") + "\n"
    }

    /// A fixture home with one extra session full of synthetic secrets, mode 0640, pinned mtime.
    private func fixtureWithSecrets() throws -> (FixtureHome, URL) {
        let fixture = try FixtureHome()
        let url = fixture.transcript(Self.flagged, project: Self.project)
        try Data(Self.transcript().utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        try FileSystem.setModificationTime(FileTime(seconds: 1_795_000_000, nanoseconds: 123_456_789), of: url)
        return (fixture, url)
    }

    private func scanAndPlan(_ fixture: FixtureHome, id: String = flagged) async throws -> (Session, SecretScanReport, Plan) {
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: id)
        let report = try await SecretScanner().scan(session, adapter: adapter)
        let plan = try await RedactionPlanner.plan(for: session, findings: report.findings, adapter: adapter)
        return (session, report, plan)
    }

    @Test("redaction keeps JSON valid, every other byte, mtime and mode; undo puts the original back")
    func roundTrip() async throws {
        let (fixture, url) = try fixtureWithSecrets()
        let before = try Data(contentsOf: url)
        let mtimeBefore = try #require(FileSystem.modificationTime(of: url))
        let (_, report, plan) = try await scanAndPlan(fixture)

        #expect(report.findings.count == SecretSamples.cases.count + 1)
        #expect(plan.action == .redact)
        #expect(plan.redactionCount == SecretSamples.cases.count)
        #expect(plan.skippedSecrets.count == 1)
        #expect(plan.skippedSecrets.first?.reason == "The line is not valid JSON.")
        #expect(plan.summary.contains("The original, with the secrets, is kept in Domovy's quarantine so you can undo. Remove it with Purge originals."))
        #expect(!plan.liveCheck.isLive)

        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(entry.redacted.count == 1)
        let after = try Data(contentsOf: url)

        // Same bytes as applying the replacements by hand.
        var expected = [UInt8](before)
        for finding in report.findings.filter(\.isRedactable).sorted(by: { $0.byteRange.lowerBound > $1.byteRange.lowerBound }) {
            expected.replaceSubrange(Int(finding.byteRange.lowerBound)..<Int(finding.byteRange.upperBound), with: Array("[REDACTED:\(finding.ruleID)]".utf8))
        }
        #expect(after == Data(expected))

        let lines = after.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).dropLast()
        for (index, line) in lines.enumerated() where index != SecretSamples.cases.count + 1 {
            #expect((try? JSONSerialization.jsonObject(with: Data(line))) != nil, "line \(index + 1) is valid JSON")
        }
        let text = String(decoding: after, as: UTF8.self)
        for sample in SecretSamples.cases where sample.rule != "aws-access-key" {
            #expect(!text.contains(sample.value.replacingOccurrences(of: "\n", with: "\\n")), "\(sample.rule) is gone")
        }
        #expect(text.components(separatedBy: SecretSamples.aws).count == 2, "only the broken line keeps its AWS key")
        #expect(text.contains("[REDACTED:anthropic-key]"))

        #expect(FileSystem.modificationTime(of: url) == mtimeBefore)
        #expect(FileSystem.posixPermissions(of: url) == 0o640)

        // The original waits in the quarantine, byte for byte, with its time.
        let kept = try #require(entry.redacted.first?.original)
        #expect(kept.path.hasPrefix(executor.quarantineDirectory.path))
        #expect(try Data(contentsOf: kept) == before)

        // The scan now finds only the finding it could not redact.
        let rescan = try await SecretScanner().scan(try await fixture.adapter().session(matching: Self.flagged), adapter: fixture.adapter())
        #expect(rescan.findings.count == 1)

        let undone = try executor.undoLatest()
        #expect(undone.isUndone)
        #expect(try Data(contentsOf: url) == before)
        #expect(FileSystem.modificationTime(of: url) == mtimeBefore)
        #expect(FileSystem.posixPermissions(of: url) == 0o640)
        #expect(!FileManager.default.fileExists(atPath: kept.path))
    }

    @Test("the undo log and plan hold no secret values, only positions and masked previews")
    func nothingPersistedInClear() async throws {
        let (fixture, _) = try fixtureWithSecrets()
        let (_, _, plan) = try await scanAndPlan(fixture)
        let executor = fixture.executor()
        _ = try executor.execute(plan)
        var texts = [String(decoding: try JSONEncoder().encode(plan), as: UTF8.self)]
        for file in FileSystem.children(of: executor.undoLog.directory) where file.pathExtension == "json" {
            texts.append(try String(contentsOf: file, encoding: .utf8))
        }
        for text in texts {
            for value in SecretSamples.allValues {
                #expect(!text.contains(value.replacingOccurrences(of: "\n", with: "\\n")))
            }
        }
    }

    @Test("purge happens only when asked, deletes exactly the planned originals, and ends undo")
    func purge() async throws {
        let (fixture, url) = try fixtureWithSecrets()
        let (_, _, plan) = try await scanAndPlan(fixture)
        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        let kept = try #require(entry.redacted.first?.original)

        let purgePlan = try executor.purgePlan()
        #expect(purgePlan.items.map(\.file) == [kept])
        #expect(purgePlan.items.first?.originalPath == url)
        #expect(purgePlan.summary.contains("cannot be undone"))
        // Computing the plan changes nothing.
        #expect(FileManager.default.fileExists(atPath: kept.path))

        let purged = try executor.purge(purgePlan)
        #expect(purged.count == 1)
        #expect(!FileManager.default.fileExists(atPath: kept.path))
        #expect(FileManager.default.fileExists(atPath: url.path), "the redacted file stays")
        #expect(try executor.undoLog.latestPending() == nil)
        let stored = try #require(try executor.undoLog.entries().first { $0.id == entry.id })
        #expect(stored.originalsPurgedAt != nil)
        #expect(throws: ExecutorError.self) { try executor.undo(stored) }
        #expect(try executor.purgePlan().isEmpty)
    }

    @Test("purge refuses a file outside the quarantine")
    func purgeRefusesOutside() throws {
        let fixture = try FixtureHome()
        let executor = fixture.executor()
        let outside = fixture.claudeDirectory.appendingPathComponent("settings.json")
        let plan = PurgePlan(items: [PurgeItem(entryID: UUID(), agent: .claudeCode, sessionID: "x", file: outside, originalPath: outside, sizeBytes: 1, reason: .redactedOriginal)])
        #expect(throws: ExecutorError.self) { try executor.purge(plan) }
        #expect(fixture.exists("settings.json"))
    }

    @Test("a session deleted to the quarantine after the scan flagged it can be purged")
    func flaggedDelete() async throws {
        let (fixture, _) = try fixtureWithSecrets()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: Self.flagged)
        var plan = try await adapter.deletePlan(for: session, destination: .quarantine)
        plan.secretFindingCount = 3
        let executor = fixture.executor()
        let entry = try executor.execute(plan)

        // The moved files, and the backups of the index files its lines were taken out of.
        let backups = entry.indexRestores.count + entry.registryRestores.count
        let purgePlan = try executor.purgePlan([.flaggedSession])
        #expect(purgePlan.items.count == entry.moved.count + backups)
        #expect(purgePlan.items.allSatisfy { $0.reason == .flaggedSession })
        #expect(try executor.purgePlan([.redactedOriginal]).isEmpty)

        // An unflagged quarantine delete is never offered for purging.
        let other = try await adapter.session(matching: IDs.idle)
        _ = try executor.execute(try await adapter.deletePlan(for: other, destination: .quarantine))
        #expect(try executor.purgePlan().items.count == entry.moved.count + backups)
    }

    @Test("refuses to redact a live session")
    func refusesLive() async throws {
        let fixture = try FixtureHome()
        let url = fixture.transcript(IDs.live, project: Self.project)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((SecretSamples.claudeLine(SecretSamples.cases[0].text, session: IDs.live) + "\n").utf8))
        try handle.close()
        let before = try Data(contentsOf: url)

        let (_, report, plan) = try await scanAndPlan(fixture, id: IDs.live)
        #expect(report.findings.count == 1)
        #expect(plan.liveCheck.isLive)
        #expect(plan.summary.hasPrefix("This session is live"))
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test("a file that changed since the scan is left alone")
    func changedSinceScan() async throws {
        let (fixture, url) = try fixtureWithSecrets()
        let (_, _, plan) = try await scanAndPlan(fixture)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((SecretSamples.claudeLine("one more message", session: Self.flagged) + "\n").utf8))
        try handle.close()
        let changed = try Data(contentsOf: url)

        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        #expect(try Data(contentsOf: url) == changed)
    }

    @Test("Codex: plain rollouts are scanned and redacted; zstd rollouts are scanned but never rewritten")
    func codex() async throws {
        let fixture = try CodexFixtureHome()
        let url = fixture.codexDirectory.appendingPathComponent(CodexFixtureHome.idleRollout)
        let line = "{\"timestamp\":\"2026-11-20T09:16:00.000Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"use \(SecretSamples.openAI) please\",\"images\":[]}}\n"
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.close()

        let adapter = fixture.adapter()
        let sessions = try await adapter.sessions()
        let targets = await SecretScanner.targets(for: sessions, adapters: [adapter])
        let report = try await SecretScanner().scan(targets)
        let plain = report.findings.filter { $0.sessionID == CodexFixtureHome.IDs.idle }
        #expect(plain.map(\.ruleID) == ["openai-key"])
        let zstd = report.findings.filter { $0.sessionID == CodexFixtureHome.IDs.compressed }
        #expect(zstd.map(\.ruleID) == ["aws-access-key"])
        #expect(zstd.first?.line == 6) // a line of the decompressed rollout
        #expect(zstd.first?.isRedactable == false)
        // The bare placeholder `.zst` is not zstd: skipped with the decoder's reason.
        #expect(report.skipped.contains { $0.sessionID == CodexFixtureHome.IDs.bare && $0.reason.contains("damaged") })

        let compressedSession = try #require(sessions.first { $0.id == CodexFixtureHome.IDs.compressed })
        let refused = try await RedactionPlanner.plan(for: compressedSession, findings: report.findings, adapter: adapter)
        #expect(refused.redactionCount == 0)
        #expect(refused.skippedSecrets.first?.reason == SecretScanner.compressedReason)

        let session = try #require(sessions.first { $0.id == CodexFixtureHome.IDs.idle })
        let plan = try await RedactionPlanner.plan(for: session, findings: plain, adapter: adapter)
        #expect(plan.redactionCount == 1)
        #expect(plan.remarks.contains { $0.contains("thread_history_1.sqlite") })
        _ = try fixture.executor().execute(plan)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("use [REDACTED:openai-key] please"))
    }
}
