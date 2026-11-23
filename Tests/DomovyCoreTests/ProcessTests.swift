import Darwin
@testable import DomovyCore
import Foundation
import Testing

/// A synthetic process table: launchd, a terminal shell, agents, their children, and orphans.
/// Domovy (999) runs inside the Claude Code session 200.
enum ProcessTable {
    static let me: UInt32 = 501

    static func p(_ pid: Int32, _ ppid: Int32, _ name: String, path: String? = nil, uid: UInt32 = me, mb: Int64 = 10,
                  cpu: UInt64? = 0, stopped: Bool = false, start: UInt64? = nil) -> RawProcess {
        RawProcess(pid: pid, ppid: ppid, uid: uid, name: name, executablePath: path ?? "/opt/test/\(name)",
                   startMicros: start ?? UInt64(pid) * 1_000, isStopped: stopped, cpuNanos: cpu, footprintBytes: mb * 1_000_000)
    }

    static let processes: [RawProcess] = [
        p(1, 0, "launchd", path: "/sbin/launchd", uid: 0),
        p(100, 1, "zsh", path: "/bin/zsh"),
        // Claude Code with an MCP server, a shell, and Domovy below it.
        p(200, 100, "claude", mb: 300),
        p(201, 200, "node", mb: 120),
        p(202, 200, "zsh", path: "/bin/zsh"),
        p(203, 202, "cargo", mb: 40),
        p(999, 200, "Domovy"),
        // Claude Desktop and a helper; Codex with a helper; Claude Code started inside Cursor.
        p(300, 1, "Claude", mb: 400),
        p(301, 300, "Claude Helper (Renderer)", mb: 200),
        p(400, 100, "codex", mb: 90),
        p(401, 400, "codex-code-mode-host", mb: 30),
        p(410, 400, "node", mb: 50),
        p(600, 1, "Cursor", mb: 500),
        p(601, 600, "Cursor Helper (Plugin)", mb: 100),
        p(602, 601, "zsh", path: "/bin/zsh"),
        p(603, 602, "claude", mb: 250),
        // Orphans: an MCP server whose client is gone; a binary from an agent's folder.
        p(500, 1, "npx", mb: 180),
        p(501, 500, "node", mb: 60),
        p(510, 1, "helper-tool", path: "/Users/test/.codex/bin/helper-tool", mb: 20),
        // Not orphans: your own server under launchd, and another user's process.
        p(700, 1, "node", mb: 80),
        p(800, 1, "nodeserver", uid: 0),
    ]

    static let arguments: [Int32: [String]] = [
        201: ["node", "/x/node_modules/@modelcontextprotocol/server-github/dist/index.js", "--token=SECRET"],
        410: ["node", "repl.js"],
        202: ["/bin/zsh", "-c", "echo mcp"],
        500: ["npx", "-y", "mcp-server-filesystem@1.2.0", "/Users/test/project"],
        501: ["node", "/cache/mcp-server-filesystem/dist/index.js"],
        700: ["node", "server.js"],
    ]

    static func source(_ processes: [RawProcess] = processes, openFiles: [Int32: [String]] = [:]) -> FixedProcessSource {
        FixedProcessSource(processes, arguments: arguments, openFiles: openFiles, currentUserID: me, ownPID: 999)
    }

    static func report(_ source: FixedProcessSource = source(), sessions: ProcessSessionResolver? = nil) -> ProcessReport {
        ProcessAnalyzer(source: source, sessions: sessions).analyze(.init(processes: source.processes ?? [])).report
    }
}

/// Plays back one table per refresh.
final class SequenceSource: ProcessSource, @unchecked Sendable {
    private let lock = NSLock()
    private var tables: [[RawProcess]]
    private var current: [RawProcess] = []
    let arguments: [Int32: [String]]
    let currentUserID: UInt32 = ProcessTable.me
    let ownPID: Int32 = 999

    init(_ tables: [[RawProcess]], arguments: [Int32: [String]] = [:]) {
        self.tables = tables
        self.arguments = arguments
    }

    func snapshot() -> [RawProcess]? {
        lock.withLock {
            if !tables.isEmpty { current = tables.removeFirst() }
            return current
        }
    }

    func process(_ pid: Int32) -> RawProcess? { lock.withLock { current.first { $0.pid == pid } } }
    func arguments(of pid: Int32) -> [String]? { arguments[pid] }
    func openFiles(of pid: Int32) -> [String]? { [] }
}

/// Records signals instead of sending them.
final class RecordingSignaler: ProcessSignaler, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var sent: [(signal: Int32, pid: Int32)] = []

    func send(_ signal: Int32, to pid: Int32) -> Int32? {
        lock.withLock { sent.append((signal, pid)) }
        return nil
    }
}

@Suite("Processes")
struct ProcessTests {
    typealias T = ProcessTable

    @Test("agents become trees: helpers, likely MCP servers, children; a nested agent gets its own tree")
    func classification() throws {
        let report = T.report()
        let roots = Dictionary(report.groups.map { ($0.root.pid, $0.root) }, uniquingKeysWith: { a, _ in a })
        #expect(Set(roots.keys) == [200, 300, 400, 600, 603])
        let claude = try #require(roots[200])
        #expect(claude.kind == .agent && claude.agent == .claudeCode && claude.name == "Claude Code")
        let mcp = try #require(claude.children.first { $0.pid == 201 })
        #expect(mcp.kind == .mcpServer)
        #expect(mcp.name == "node @modelcontextprotocol/server-github")
        #expect(!mcp.name.contains("SECRET"))
        // A shell whose command line mentions MCP is not an MCP server.
        #expect(claude.children.first { $0.pid == 202 }?.kind == .child)
        #expect(roots[300]?.children.first?.kind == .helper)
        #expect(roots[300]?.agent == .claudeDesktop)
        #expect(roots[400]?.children.first { $0.pid == 401 }?.kind == .helper)
        #expect(roots[400]?.children.first { $0.pid == 410 }?.kind == .child)
        // Cursor's tree stops where Claude Code started inside its terminal.
        #expect(!(roots[600]?.subtree.contains { $0.pid == 603 } ?? true))
        #expect(claude.totalBytes == (300 + 120 + 10 + 40 + 10) * 1_000_000)
    }

    @Test("orphans: reparented MCP servers and binaries from an agent's folder; not your own servers or other users'")
    func orphans() throws {
        let report = T.report()
        #expect(Set(report.orphans.map(\.pid)) == [500, 510])
        let mcp = try #require(report.orphans.first { $0.pid == 500 })
        #expect(mcp.isOrphan && mcp.kind == .mcpServer && mcp.agent == nil)
        #expect(mcp.name == "npx mcp-server-filesystem")
        #expect(mcp.children.map(\.pid) == [501])
        #expect(report.orphans.first { $0.pid == 510 }?.agent == .codex)
        #expect(report.orphanBytes == (180 + 60 + 20) * 1_000_000)
    }

    @Test("Domovy, its parents, macOS tools and other users' processes are refused")
    func refusals() throws {
        let report = T.report()
        #expect(report.node(pid: 999)?.refusal == "This is Domovy itself.")
        #expect(report.node(pid: 200)?.refusal?.contains("Domovy runs inside") == true)
        #expect(report.node(pid: 202)?.refusal?.contains("part of macOS") == true)
        #expect(report.node(pid: 201)?.refusal == nil)
        let other = ProcessAnalyzer(source: T.source(), sessions: nil).analyze(.init(processes: T.processes + [T.p(900, 300, "Claude Helper", uid: 0)])).report
        #expect(other.node(pid: 900)?.refusal?.contains("another user") == true)
    }

    @Test("sessions: Claude Code sessions/<pid>.json and roster workers, Codex writer locks")
    func sessions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-ps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let sessions = home.appendingPathComponent(".claude/sessions", isDirectory: true)
        let daemon = home.appendingPathComponent(".claude/daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: daemon, withIntermediateDirectories: true)
        try Data(#"{"pid":200,"sessionId":"AAAA-1111"}"#.utf8).write(to: sessions.appendingPathComponent("200.json"))
        try Data(#"{"workers":{"w1":{"pid":603,"sessionId":"bbbb-2222"}}}"#.utf8).write(to: daemon.appendingPathComponent("roster.json"))
        let lock = home.appendingPathComponent(".codex/thread-writer-locks/0199-thread.lock").path
        let report = T.report(T.source(openFiles: [400: [lock, "/elsewhere/thread-writer-locks/x.lock"]]), sessions: ProcessSessionResolver(home: home))
        #expect(report.groups.first { $0.root.pid == 200 }?.sessionIDs == ["aaaa-1111"])
        #expect(report.groups.first { $0.root.pid == 603 }?.sessionIDs == ["bbbb-2222"])
        #expect(report.groups.first { $0.root.pid == 400 }?.sessionIDs == ["0199-thread"])
    }

    @Test("CPU from two samples; a process seen in an agent's tree is an orphan once reparented")
    func watcherOverTime() async throws {
        let first = [T.p(1, 0, "launchd", path: "/sbin/launchd", uid: 0), T.p(200, 1, "claude", cpu: 0), T.p(210, 200, "rg", cpu: 1_000_000_000)]
        let second = [T.p(1, 0, "launchd", path: "/sbin/launchd", uid: 0), T.p(210, 1, "rg", cpu: 1_500_000_000)]
        let clock = Clock()
        let watcher = ProcessWatcher(source: SequenceSource([first, second]), sessions: nil, now: { clock.tick() })
        let before = try #require(await watcher.refresh())
        #expect(before.node(pid: 210)?.cpuPercent == nil)
        #expect(before.orphans.isEmpty)
        let after = try #require(await watcher.refresh())
        let orphan = try #require(after.orphans.first)
        #expect(orphan.pid == 210 && orphan.agent == .claudeCode && orphan.kind == .child)
        #expect(abs((orphan.cpuPercent ?? 0) - 50) < 0.001)
    }

    @Test("growing: memory rising faster than the policy over enough history; reused pids start fresh")
    func growth() {
        let policy = GrowthPolicy(bytes: 500_000_000, interval: 600, minimumObservation: 120)
        var history = MemoryHistory(policy: policy)
        let leak = ProcessKey(pid: 1, startMicros: 1), calm = ProcessKey(pid: 2, startMicros: 2)
        let start = Date(timeIntervalSince1970: 1_000_000)
        for (seconds, mb) in [(0, 100), (60, 300), (150, 700)] {
            history.record([leak: Int64(mb) * 1_000_000, calm: Int64(100 + seconds / 3) * 1_000_000], at: start.addingTimeInterval(TimeInterval(seconds)))
            if seconds == 60 { #expect(!history.isGrowing(leak)) } // not enough history yet
        }
        #expect(history.isGrowing(leak))
        #expect(history.growth(of: leak)?.bytes == 600_000_000)
        #expect(!history.isGrowing(calm))
        // The process is gone and its pid comes back with another start time.
        history.record([ProcessKey(pid: 1, startMicros: 9): 900_000_000], at: start.addingTimeInterval(160))
        #expect(history.growth(of: leak) == nil)
        #expect(!history.isGrowing(ProcessKey(pid: 1, startMicros: 9)))
    }

    @Test("quit only orphans; freeze a tree parents first and leave macOS tools alone; resume only frozen")
    func plans() throws {
        let report = T.report()
        let controller = ProcessController(source: T.source(), signaler: RecordingSignaler(), log: nil)

        let quitAgent = try controller.plan(.quit, pid: 400, in: report)
        #expect(!quitAgent.canExecute && quitAgent.suggestion == .freeze)
        #expect(quitAgent.refusals.first?.contains("never quits an agent") == true)
        let quitChild = try controller.plan(.quit, pid: 201, in: report)
        #expect(!quitChild.canExecute && quitChild.refusals.first?.contains("still belongs to Claude Code") == true)

        let quitOrphan = try controller.plan(.quit, pid: 500, in: report)
        #expect(quitOrphan.canExecute)
        #expect(quitOrphan.targets.map(\.pid) == [501, 500])

        let freeze = try controller.plan(.freeze, pid: 400, in: report)
        #expect(freeze.canExecute && freeze.targets.first?.pid == 400 && Set(freeze.targets.map(\.pid)) == [400, 401, 410])
        let session = try controller.plan(.freeze, pid: 200, in: report)
        #expect(!session.canExecute) // Domovy runs inside it
        let cursor = try controller.plan(.freeze, pid: 600, in: report)
        #expect(cursor.leftAlone.map(\.pid) == [602])
        #expect(!cursor.targets.contains { $0.pid == 602 || $0.pid == 603 })

        #expect(try !controller.plan(.resume, pid: 400, in: report).canExecute)
        #expect(throws: ProcessActionError.self) { try controller.plan(.freeze, pid: 700, in: report) }
    }

    @Test("execution re-checks each process: a reused pid is skipped; a frozen orphan gets SIGCONT after SIGTERM")
    func execution() async throws {
        let report = T.report()
        let signaler = RecordingSignaler()
        // Since the report, 410 exited and its pid went to a new process; 500 is frozen.
        var now = T.processes.filter { $0.pid != 410 && $0.pid != 500 }
        now += [T.p(410, 400, "node", start: 7), T.p(500, 1, "npx", stopped: true)]
        let controller = ProcessController(source: T.source(now), signaler: signaler, log: nil)
        let freeze = try await controller.execute(try controller.plan(.freeze, pid: 400, in: report))
        #expect(freeze.signaled.map(\.pid) == [400, 401])
        #expect(freeze.skipped.first?.contains("already exited") == true)
        #expect(signaler.sent.allSatisfy { $0.signal == SIGSTOP })

        let quit = try await controller.execute(try controller.plan(.quit, pid: 500, in: report), timeout: 0.2)
        #expect(signaler.sent.suffix(3).map(\.signal) == [SIGTERM, SIGTERM, SIGCONT])
        #expect(quit.stillRunning.map(\.pid).sorted() == [500, 501]) // the fixed table never lets them exit
        let force = controller.forceQuitPlan(after: quit, of: try controller.plan(.quit, pid: 500, in: report))
        #expect(force.action == .forceQuit && force.canExecute && force.targets.count == 2)
    }

    @Test("action records are logged with names and pids only")
    func actionLog() async throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-pslog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: store) }
        let log = ProcessActionLog(storeRoot: store)
        let controller = ProcessController(source: T.source(), signaler: RecordingSignaler(), log: log)
        _ = try await controller.execute(try controller.plan(.freeze, pid: 400, in: T.report()))
        let record = try #require(log.records().first)
        #expect(record.action == .freeze && record.rootPID == 400 && record.signaled == 3 && record.agent == .codex)
        let text = try String(contentsOf: log.file, encoding: .utf8)
        #expect(!text.contains("repl.js"))
        #expect(try Executor(storeRoot: store).undoLog.entries().isEmpty) // never mistaken for an undo entry
    }

    @Test("labels: package names only, never URLs, options or values")
    func labels() {
        #expect(ProcessClassifier.packageLabel("@playwright/mcp@latest") == "@playwright/mcp")
        #expect(ProcessClassifier.packageLabel("/x/servers/my_mcp.py") == "my_mcp")
        #expect(ProcessClassifier.packageLabel("https://mcp.example.com/?key=abc") == nil)
        #expect(ProcessClassifier.packageLabel("--mcp-token=abc") == nil)
        #expect(ProcessClassifier.mentionsMCP("xcodebuildmcp"))
        #expect(!ProcessClassifier.mentionsMCP("compact"))
    }
}

/// Advances one second per reading.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 2_000_000)

    func tick() -> Date {
        lock.withLock {
            defer { date = date.addingTimeInterval(1) }
            return date
        }
    }
}
