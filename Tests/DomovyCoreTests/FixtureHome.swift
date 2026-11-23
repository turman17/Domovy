import DomovyCore
import Foundation
import Testing

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
    /// Linked to Claude Desktop's registry once `installDesktop()` copied it; Desktop is not
    /// running unless `desktopProcesses` says so.
    func adapter(
        now: @escaping @Sendable () -> Date = { Date() },
        openHandles: any OpenHandleChecker = UnavailableOpenHandleChecker(),
        processes: any ProcessProbe = FixedProcessProbe(running: FixtureHome.markerPIDs),
        desktopProcesses: any RunningProcessLister = FixedProcessLister([])
    ) -> ClaudeCodeAdapter {
        ClaudeCodeAdapter(
            configDirectory: claudeDirectory,
            openHandles: openHandles,
            processes: processes,
            desktopRegistry: FileManager.default.fileExists(atPath: registryDirectory.path) ? ClaudeDesktopRegistry(directory: registryDirectory) : nil,
            desktopProcesses: desktopProcesses,
            now: now
        )
    }

    /// Never libproc: the apps a plan must not run alongside are whatever `running` says.
    func executor(running: [RunningProcess] = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    // MARK: Claude Desktop

    /// Synthetic ids of the claude-desktop fixture's registry (`claude-code-sessions/`).
    enum Desktop {
        static let folder = "3f6e1a2b-0c4d-4e5f-8a9b-1c2d3e4f5a6b/9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
        /// Links the idle session.
        static let idleEntry = 1
        /// Two entries for the expiring session; the second is newer.
        static let expiringOlder = 2
        static let expiringNewer = 3
        /// Its transcript does not exist.
        static let orphanEntry = 4
        static let orphanCLI = "ffffffff-6666-4666-8666-666666666666"
    }

    var desktopSupport: URL { home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true) }
    var registryDirectory: URL { desktopSupport.appendingPathComponent("claude-code-sessions", isDirectory: true) }

    func registryFile(_ number: Int) -> URL {
        registryDirectory.appendingPathComponent("\(Desktop.folder)/local_5e1d2f3a-0000-4000-8000-00000000000\(number).json")
    }

    /// Copies `claude-desktop/1.0` into the home. Registry entries get pinned ages: all two
    /// days old, the newer duplicate one day.
    func installDesktop(now: Date = Date()) throws {
        try FileManager.default.createDirectory(at: desktopSupport.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.fixturesRoot.appendingPathComponent("claude-desktop/1.0", isDirectory: true), to: desktopSupport)
        for number in 1...4 {
            let age: TimeInterval = number == Desktop.expiringNewer ? 86_400 : 2 * 86_400
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: registryFile(number).path)
        }
    }

    /// Rewrites one registry entry's JSON, keeping its modification time.
    func editRegistry(_ number: Int, _ change: (inout [String: Any]) -> Void) throws {
        let url = registryFile(number)
        let date = try #require(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
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
