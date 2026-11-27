@testable import DomovyCore
import Foundation
import Testing

/// Open files that change from one snapshot to the next, the way a process opens a file while
/// a batch runs. Snapshot `n` (from 1) reports `open(n)`; `nil` means it could not be taken.
private final class ChangingProcessLister: RunningProcessLister, @unchecked Sendable {
    private let lock = NSLock()
    private var taken = 0
    private let open: @Sendable (Int) -> [OpenHandleHolder]?

    init(_ open: @escaping @Sendable (Int) -> [OpenHandleHolder]?) {
        self.open = open
    }

    var snapshots: Int { lock.withLock { taken } }

    func running(matching matcher: ProcessMatcher) -> [RunningProcess]? { [] }
    func openFiles(of pid: Int32) -> [String]? { [] }
    func holders(of urls: [URL]) -> [OpenHandleHolder]? { openFileSnapshot().map { matchOpenPaths($0, against: urls) } }

    func openFileSnapshot() -> [OpenHandleHolder]? {
        let n = lock.withLock { taken += 1; return taken }
        return open(n)
    }
}

@Suite("Executor: one open-file snapshot per batch")
struct BatchExecutorTests {
    typealias IDs = FixtureHome.ClaudeCode

    /// Delete plans for the idle and the expiring session, in that order.
    private func twoPlans(_ fixture: FixtureHome) async throws -> [Plan] {
        let adapter = fixture.adapter()
        let sessions = [try await adapter.session(matching: IDs.idle), try await adapter.session(matching: IDs.expiring)]
        let plans = await adapter.deletePlans(for: sessions, destination: .quarantine).compactMap(\.plan)
        try #require(plans.count == 2 && plans.allSatisfy { !$0.moves.isEmpty })
        return plans
    }

    private func transcript(of plan: Plan) throws -> URL {
        try #require(plan.moves.first { $0.source.pathExtension == "jsonl" && !$0.source.lastPathComponent.hasPrefix(".") }?.source)
    }

    @Test("a batch younger than the age bound takes one snapshot for all its checks")
    func oneSnapshot() async throws {
        let fixture = try FixtureHome()
        let plans = try await twoPlans(fixture)
        let lister = ChangingProcessLister { _ in [] }
        var executor = Executor(storeRoot: fixture.storeRoot, processes: lister)
        executor.openFiles = OpenFileSnapshots(maxAge: .seconds(3600))
        let entries = try executor.execute(plans)
        #expect(entries.count == 2)
        #expect(lister.snapshots == 1)
        _ = try executor.undoLatestBatch()
        #expect(lister.snapshots == 1, "undo within the bound shares it too")
    }

    @Test("a file opened mid-batch is refused once the snapshot is older than the bound")
    func openedMidBatch() async throws {
        let fixture = try FixtureHome()
        let plans = try await twoPlans(fixture)
        let second = try transcript(of: plans[1])
        // Clear at the first snapshot; from the second on, an editor holds the second session's transcript.
        let lister = ChangingProcessLister { n in
            n == 1 ? [] : [OpenHandleHolder(pid: 4711, processName: "vim", path: second.standardizedFileURL.path)]
        }
        var executor = Executor(storeRoot: fixture.storeRoot, processes: lister)
        executor.openFiles = OpenFileSnapshots(maxAge: .zero)
        #expect {
            try executor.execute(plans)
        } throws: { error in
            guard case ExecutorError.filesOpen(let reasons) = error else { return false }
            return reasons.contains { $0.contains("vim (pid 4711)") }
        }
        #expect(FileManager.default.fileExists(atPath: second.path), "the second session was not touched")
        let first = try transcript(of: plans[0])
        #expect(!FileManager.default.fileExists(atPath: first.path), "the first session ran before the file was opened")
        // What ran is undoable.
        _ = try executor.undoLatestBatch()
        #expect(FileManager.default.fileExists(atPath: first.path))
    }

    @Test("a snapshot that cannot be taken refuses the change, never an older answer")
    func failsClosed() async throws {
        let fixture = try FixtureHome()
        let plans = try await twoPlans(fixture)
        let lister = ChangingProcessLister { n in n == 1 ? [] : nil }
        var executor = Executor(storeRoot: fixture.storeRoot, processes: lister)
        executor.openFiles = OpenFileSnapshots(maxAge: .zero)
        #expect {
            try executor.execute(plans)
        } throws: { error in
            guard case ExecutorError.filesOpen(let reasons) = error else { return false }
            return reasons.contains { $0.contains("could not check") }
        }
        #expect(FileManager.default.fileExists(atPath: try transcript(of: plans[1]).path))
    }

    @Test("the snapshot is retaken once older than its age bound, measured from when its walk began")
    func ageBound() throws {
        let now = LockedBox(ContinuousClock.now)
        let snapshots = OpenFileSnapshots(maxAge: .milliseconds(250), clock: { now.value })
        let file = URL(fileURLWithPath: "/tmp/domovy-age-bound/file.jsonl")
        let lister = ChangingProcessLister { n in
            n == 1 ? [] : [OpenHandleHolder(pid: 4711, processName: "vim", path: file.path)]
        }
        #expect(snapshots.holders(of: [file], from: lister) == [])
        now.value += .milliseconds(200)
        #expect(snapshots.holders(of: [file], from: lister) == [], "still young: shared")
        #expect(lister.snapshots == 1)
        now.value += .milliseconds(100)
        #expect(snapshots.holders(of: [file], from: lister)?.map(\.pid) == [4711], "too old: retaken")
        #expect(lister.snapshots == 2)
    }

    @Test("with real libproc and the default bound, a process that opens a file mid-batch is refused")
    func realProcessOpensMidBatch() async throws {
        let fixture = try FixtureHome()
        let plans = try await twoPlans(fixture)
        let second = try transcript(of: plans[1])
        let tail = Process()
        tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        tail.arguments = ["-f", second.path]
        tail.standardOutput = FileHandle.nullDevice
        defer { if tail.isRunning { tail.terminate() } }
        var executor = Executor(storeRoot: fixture.storeRoot)
        let started = LockedBox(false)
        // Runs inside the first plan, after its own check: `tail` opens the second transcript,
        // and the batch goes on longer than the bound, as a large batch does.
        executor.indexRewriteHook = { _ in
            guard !started.value else { return }
            started.value = true
            try? tail.run()
            var tries = 0
            while tries < 200, LibprocOpenHandleChecker.currentHolders(of: [second])?.isEmpty != false {
                tries += 1
                usleep(10_000)
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        #expect {
            try executor.execute(plans)
        } throws: { error in
            guard case ExecutorError.filesOpen(let reasons) = error else { return false }
            return reasons.contains { $0.contains("tail") }
        }
        #expect(started.value)
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}

/// A value tests change from a `@Sendable` closure.
private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
