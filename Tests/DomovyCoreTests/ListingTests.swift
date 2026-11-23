@testable import DomovyCore
import Foundation
import Testing

/// A listing reads shared files once and asks about open files once for all sessions. What it
/// reports must equal what each session's own artifacts and live check say.
@Suite("Listing")
struct ListingTests {
    @Test("Claude Code: listed sizes and statuses equal each session's artifacts and live check")
    func claudeCode() async throws {
        let fixture = try FixtureHome()
        try fixture.installDesktop()
        typealias IDs = FixtureHome.ClaudeCode
        // A large companion puts one session among those whose mapped files are checked too.
        let big = fixture.claudeDirectory.appendingPathComponent("projects/-Users-dev-code-landing-site/\(IDs.expiring)/big.bin")
        try FileManager.default.createDirectory(at: big.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        #expect(truncate(big.path, off_t(LibprocOpenHandleChecker.mappedFileThreshold)) == 0)

        let holders = [
            OpenHandleHolder(pid: 777, processName: "claude", path: fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api").path),
            OpenHandleHolder(pid: 778, processName: "vim", path: big.path),
        ]
        let adapter = fixture.adapter(openHandles: PrefixOpenHandleChecker(holders: holders))
        let sessions = try await adapter.sessions()
        #expect(sessions.count == 4)
        for session in sessions {
            let artifacts = try await adapter.artifacts(of: session)
            #expect(session.sizeBytes == artifacts.reduce(0) { $0 + $1.sizeBytes }, "\(session.id)")
            let check = try await adapter.liveCheck(session)
            #expect((session.status == .live) == check.isLive, "\(session.id)")
        }
        #expect(sessions.first { $0.id == IDs.idle }?.status == .live)
        #expect(sessions.first { $0.id == IDs.expiring }?.status == .live)

        // History lines found by the listing are the ones a plan edits.
        let plan = try await adapter.deletePlan(for: try #require(sessions.first { $0.id == IDs.idle }))
        let listed = try await adapter.artifacts(of: try #require(sessions.first { $0.id == IDs.idle }))
        #expect(plan.indexEdits.first?.removedBytes == listed.first { $0.url == fixture.claudeDirectory.appendingPathComponent("history.jsonl").standardizedFileURL }?.sizeBytes)

        // The open-file check cannot run: nothing is live through it, the markers still count.
        let unavailable = fixture.adapter(openHandles: PrefixOpenHandleChecker(holders: nil))
        for session in try await unavailable.sessions() {
            let check = try await unavailable.liveCheck(session)
            #expect(check.openHandles == .unavailable)
            #expect((session.status == .live) == check.isLive, "\(session.id)")
        }
    }

    @Test("Codex: listed sizes and statuses equal each session's artifacts and live check")
    func codex() async throws {
        let fixture = try CodexFixtureHome()
        typealias IDs = CodexFixtureHome.IDs
        let lock = fixture.url("thread-writer-locks/\(IDs.live).lock").standardizedFileURL.path
        let adapter = fixture.adapter(openHandles: PrefixOpenHandleChecker(holders: [OpenHandleHolder(pid: 69_629, processName: "codex", path: lock)]))
        let sessions = try await adapter.sessions()
        #expect(sessions.count == 5)
        for session in sessions {
            let artifacts = try await adapter.artifacts(of: session)
            #expect(session.sizeBytes == artifacts.reduce(0) { $0 + $1.sizeBytes }, "\(session.id)")
            let check = try await adapter.liveCheck(session)
            #expect((session.status == .live) == check.isLive, "\(session.id)")
        }
        #expect(sessions.filter { $0.status == .live }.map(\.id) == [IDs.live])
    }

    @Test("Gemini CLI: listed sizes and statuses equal each session's artifacts and live check")
    func gemini() async throws {
        let fixture = try GeminiFixtureHome()
        let path = fixture.url(GeminiFixtureHome.idleChat).standardizedFileURL.path
        let adapter = fixture.adapter(openHandles: PrefixOpenHandleChecker(holders: [OpenHandleHolder(pid: 42, processName: "node", path: path)]))
        let sessions = try await adapter.sessions()
        #expect(sessions.count == 4)
        for session in sessions {
            let artifacts = try await adapter.artifacts(of: session).filter { $0.kind != .indexEntry }
            #expect(session.sizeBytes == artifacts.reduce(0) { $0 + $1.sizeBytes }, "\(session.id)")
            let check = try await adapter.liveCheck(session)
            #expect((session.status == .live) == check.isLive, "\(session.id)")
        }
        #expect(sessions.filter { $0.status == .live }.map(\.id) == [GeminiFixtureHome.IDs.idle])
    }

    @Test("one open-file question for many sessions gives each the holders its own question would")
    func batchedHolders() async throws {
        let root = URL(fileURLWithPath: "/tmp/domovy-listing-\(UUID().uuidString)")
        let groups = [
            [root.appendingPathComponent("a/one.jsonl")],
            [root.appendingPathComponent("b"), root.appendingPathComponent("c.jsonl")],
            [],
            [root.appendingPathComponent("d.jsonl")],
        ]
        let holders = [
            OpenHandleHolder(pid: 1, processName: "x", path: root.appendingPathComponent("a/one.jsonl").path),
            OpenHandleHolder(pid: 2, processName: "y", path: root.appendingPathComponent("b/deep/file").path),
            OpenHandleHolder(pid: 3, processName: "z", path: root.appendingPathComponent("bb/file").path),
        ]
        let checker = PrefixOpenHandleChecker(holders: holders)
        let batched = await openHandleHolders(of: groups, checker: checker)
        for (group, result) in zip(groups, batched) {
            #expect(result == (await checker.holders(of: group)))
        }
        let none = await openHandleHolders(of: groups, checker: PrefixOpenHandleChecker(holders: nil))
        #expect(none.allSatisfy { $0 == nil })
    }

    @Test("open paths match the same way for a few URLs and for many")
    func matchingPaths() {
        let root = "/tmp/domovy-match"
        let holders = ["\(root)/a", "\(root)/a/b/c", "\(root)/ab", "\(root)/x/y", "/elsewhere/a", "\(root)/a/"]
            .enumerated().map { OpenHandleHolder(pid: Int32($0.offset), processName: "p", path: $0.element) }
        func reference(_ urls: [URL]) -> [OpenHandleHolder] {
            let paths = urls.map(\.standardizedFileURL.path)
            return holders.filter { holder in paths.contains { holder.path == $0 || holder.path.hasPrefix($0 + "/") } }
        }
        let few = [URL(fileURLWithPath: "\(root)/a"), URL(fileURLWithPath: "\(root)/x")]
        let many = few + (0..<40).map { URL(fileURLWithPath: "\(root)/other\($0)") }
        #expect(matchOpenPaths(holders, against: few) == reference(few))
        #expect(matchOpenPaths(holders, against: many) == reference(many))
        #expect(matchOpenPaths(holders, against: many).map(\.pid) == [0, 1, 3, 5])
    }

    @Test("non-empty lines are split exactly as Data.split does")
    func lines() {
        let samples = ["", "\n", "\n\n", "a", "a\n", "\na", "a\nb", "a\n\nb\n", "{\"k\":1}\n{\"k\":2}\n\n{\"k\":3}", "é\nü\n"]
        for text in samples {
            let data = Data(text.utf8)
            #expect(JSONLines.nonEmptyLines(data) == data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true), "\(text.debugDescription)")
            // A slice that does not start at zero, as `prefix` and `dropFirst` hand out.
            let slice = Data(("x\n" + text).utf8).dropFirst(2)
            #expect(JSONLines.nonEmptyLines(slice) == slice.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true), "\(text.debugDescription)")
        }
    }
}
