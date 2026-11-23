import DomovyCore
import Foundation

/// A throwaway home with Claude Code, Codex and Claude Desktop copied from the fixtures, plus
/// the extras the Disk cleanups act on: an Agent SDK venv and a Codex logs database.
final class CleanupFixtureHome: Sendable {
    let home: URL
    let storeRoot: URL
    var claude: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    var codex: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    var desktop: URL { home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true) }

    init() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-cleanup-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fixtures = FixtureHome.fixturesRoot
        try fm.copyItem(at: fixtures.appendingPathComponent("claude-code/2.1"), to: claude)
        try fm.copyItem(at: fixtures.appendingPathComponent("codex/0.169"), to: codex)
        try fm.copyItem(at: fixtures.appendingPathComponent("claude-desktop/1.0"), to: desktop)
        try write(".claude/security/agent-sdk-venv/lib/site.py")
        for name in ["logs_2.sqlite", "logs_2.sqlite-wal", "logs_2.sqlite-shm"] { try write(".codex/\(name)") }
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Deterministic: fixed process list and open files, never libproc.
    /// - Parameter holders: what has files open; `nil` means the check cannot run.
    func planner(running: [RunningProcess]? = [], openFiles: [Int32: [String]] = [:], holders: [OpenHandleHolder]? = []) -> CleanupPlanner {
        CleanupPlanner(
            claudeCodeRoot: claude,
            codexRoot: codex,
            desktopSupport: desktop,
            openHandles: PrefixOpenHandleChecker(holders: holders),
            processes: FixedProcessLister(running, openFiles: openFiles)
        )
    }

    func executor(running: [RunningProcess] = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }

    func write(_ relative: String, _ text: String = "synthetic\n") throws {
        let file = url(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    /// A file of `bytes` logical length that allocates almost nothing.
    func sparse(_ relative: String, bytes: UInt64) throws {
        try write(relative, "{\"type\":\"session_meta\"}\n")
        let handle = try FileHandle(forWritingTo: url(relative))
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    func modificationDate(_ relative: String) -> Date? {
        (try? url(relative).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func setDate(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(relative).path)
    }

    /// git with no user or system config, so a developer's settings never leak into tests.
    @discardableResult
    func git(_ arguments: [String], in folder: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Dev", "-c", "user.email=dev@example.invalid", "-c", "commit.gpgsign=false", "-C", folder.path] + arguments
        process.environment = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "HOME": home.path, "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) failed"])
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A repository at `code/orbit-api` with one commit on `main`.
    func makeRepository() throws -> URL {
        let repo = url("code/orbit-api")
        try write("code/orbit-api/README.md", "# orbit-api\n")
        try git(["init", "-q", "-b", "main"], in: repo)
        try git(["add", "README.md"], in: repo)
        try git(["commit", "-q", "-m", "Initial commit"], in: repo)
        return repo
    }
}

/// Holders for any path equal to or below a planned URL; `nil` holders means "cannot check".
struct PrefixOpenHandleChecker: OpenHandleChecker {
    let holders: [OpenHandleHolder]?

    func holders(of urls: [URL]) async -> [OpenHandleHolder]? {
        guard let holders else { return nil }
        let bases = urls.map(\.standardizedFileURL.path)
        return holders.filter { holder in bases.contains { holder.path == $0 || holder.path.hasPrefix($0 + "/") } }
    }
}
