import DomovyCore
import Foundation
import Testing

/// Test double: reports fixed holders for whatever is asked.
struct StubOpenHandleChecker: OpenHandleChecker {
    let holders: [OpenHandleHolder]?

    func holders(of urls: [URL]) async -> [OpenHandleHolder]? {
        holders
    }
}

@Suite("Liveness")
struct LivenessTests {
    typealias IDs = FixtureHome.ClaudeCode

    @Test("a sessions/<pid>.json whose pid is gone is stale and does not make the session live")
    func staleMarkers() async throws {
        let fixture = try FixtureHome()
        // Neither the CLI (4242) nor the roster worker (9002) exists any more.
        let adapter = fixture.adapter(processes: FixedProcessProbe(running: []))
        let sessions = try await adapter.sessions()
        #expect(sessions.first { $0.id == IDs.live }?.status == .idle)
        #expect(sessions.first { $0.id == IDs.rosterLive }?.status == .idle)

        let check = try await adapter.liveCheck(adapter.session(matching: IDs.live))
        #expect(!check.isLive)
        #expect(check.reasons.isEmpty)
        #expect(check.checkedSignals.contains("sessions/*.json"))

        // Only the CLI pid is back: that session is live again, the roster one is not.
        let partial = fixture.adapter(processes: FixedProcessProbe(running: [4242]))
        let again = try await partial.sessions()
        #expect(again.first { $0.id == IDs.live }?.status == .live)
        #expect(again.first { $0.id == IDs.rosterLive }?.status == .idle)
    }

    @Test("an open file handle makes an otherwise idle session live, naming the process")
    func openHandleViaStub() async throws {
        let fixture = try FixtureHome()
        let transcript = fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api")
        let holder = OpenHandleHolder(pid: 777, processName: "claude", path: transcript.path)
        let adapter = fixture.adapter(openHandles: StubOpenHandleChecker(holders: [holder]))

        let check = try await adapter.liveCheck(adapter.session(matching: IDs.idle))
        #expect(check.isLive)
        #expect(check.openHandles == .open)
        #expect(check.reasons == ["claude (pid 777) has a file of this session open."])

        let plan = try await adapter.deletePlan(for: adapter.session(matching: IDs.idle), destination: .quarantine)
        #expect(plan.liveCheck.isLive)
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }

        let clear = fixture.adapter(openHandles: StubOpenHandleChecker(holders: []))
        let clearCheck = try await clear.liveCheck(clear.session(matching: IDs.idle))
        #expect(!clearCheck.isLive)
        #expect(clearCheck.openHandles == .clear)
    }

    @Test("libproc finds a file this very process holds open, and nothing when it is closed")
    func libproc() async throws {
        let fixture = try FixtureHome()
        let transcript = fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api")
        let checker = LibprocOpenHandleChecker(cacheLifetime: 0)

        let handle = try FileHandle(forReadingFrom: transcript)
        let holders = try #require(await checker.holders(of: [transcript]))
        let mine = holders.filter { $0.pid == getpid() }
        #expect(mine.count == 1, "\(holders)")
        #expect(mine.first?.path.hasSuffix("/\(IDs.idle).jsonl") == true)
        #expect(mine.first?.processName.isEmpty == false)

        // Asking for the parent folder matches too.
        let folder = try #require(await checker.holders(of: [transcript.deletingLastPathComponent()]))
        #expect(folder.contains { $0.pid == getpid() })

        try handle.close()
        let after = try #require(await checker.holders(of: [transcript]))
        #expect(!after.contains { $0.pid == getpid() })

        // The whole adapter path, with the real checker.
        let adapter = fixture.adapter(openHandles: checker)
        let check = try await adapter.liveCheck(adapter.session(matching: IDs.idle))
        #expect(check.openHandles == .clear)
        #expect(!check.isLive)
    }

    @Test("kill(pid, 0) probe: this process runs, a finished child does not")
    func killProbe() throws {
        let probe = KillProcessProbe()
        #expect(probe.isRunning(getpid()))
        #expect(!probe.isRunning(0))
        #expect(!probe.isRunning(-1))

        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try child.run()
        child.waitUntilExit()
        #expect(!probe.isRunning(child.processIdentifier))
    }
}
