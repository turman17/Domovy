import DomovyCore
import Foundation

/// A throwaway home directory built from `Tests/Fixtures/<agent>/<version>/`.
/// Tests never touch the real home; everything happens under a unique temp folder.
final class FixtureHome: Sendable {
    /// Synthetic session ids used by the claude-code fixture.
    enum ClaudeCode {
        static let idle = "aaaaaaaa-1111-4111-8111-111111111111"
        static let live = "bbbbbbbb-2222-4222-8222-222222222222"
        static let expiring = "cccccccc-3333-4333-8333-333333333333"
        static let rosterLive = "dddddddd-4444-4444-8444-444444444444"
    }

    let home: URL
    let storeRoot: URL
    var claudeDirectory: URL { home.appendingPathComponent(".claude", isDirectory: true) }

    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DomovyCoreTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Copies `claude-code/<version>` into `<tmp>/home/.claude` and pins modification times
    /// relative to `now` so retention math is deterministic.
    init(claudeCodeVersion version: String = "2.1", now: Date = Date()) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let source = Self.fixturesRoot.appendingPathComponent("claude-code/\(version)", isDirectory: true)
        try fm.copyItem(at: source, to: claudeDirectory)

        let day: TimeInterval = 86_400
        try setTranscriptDate(ClaudeCode.idle, project: "-Users-dev-code-orbit-api", now.addingTimeInterval(-2 * day))
        try setTranscriptDate(ClaudeCode.live, project: "-Users-dev-code-orbit-api", now.addingTimeInterval(-1 * 3_600))
        try setTranscriptDate(ClaudeCode.expiring, project: "-Users-dev-code-landing-site", now.addingTimeInterval(-26 * day))
        try setTranscriptDate(ClaudeCode.rosterLive, project: "-Users-dev-code-landing-site", now.addingTimeInterval(-10 * day))
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func transcript(_ id: String, project: String) -> URL {
        claudeDirectory.appendingPathComponent("projects/\(project)/\(id).jsonl")
    }

    func setTranscriptDate(_ id: String, project: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: transcript(id, project: project).path)
    }

    /// Pids the fixture's liveness files refer to: `sessions/4242.json` and roster worker 9002.
    static let markerPIDs: Set<Int32> = [4242, 9002]

    /// Deterministic liveness: no libproc, and only the fixture's own marker pids "run".
    func adapter(
        now: @escaping @Sendable () -> Date = { Date() },
        openHandles: any OpenHandleChecker = UnavailableOpenHandleChecker(),
        processes: any ProcessProbe = FixedProcessProbe(running: FixtureHome.markerPIDs)
    ) -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(configDirectory: claudeDirectory, openHandles: openHandles, processes: processes, now: now)
    }

    func executor() -> Executor {
        Executor(storeRoot: storeRoot)
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: claudeDirectory.appendingPathComponent(relative).path)
    }

    func modificationDate(_ relative: String) -> Date? {
        (try? claudeDirectory.appendingPathComponent(relative).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func contents(_ relative: String) throws -> String {
        try String(contentsOf: claudeDirectory.appendingPathComponent(relative), encoding: .utf8)
    }
}
