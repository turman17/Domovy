@testable import DomovyCore
import Foundation
import Testing

/// Herdr: parsing its CLI's JSON (shapes recorded from 0.9.5, names made up), pane grouping and
/// orphan exclusion, live reasons, and the resume commands.
struct HerdrTests {
    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: FixtureHome.fixturesRoot.appendingPathComponent("herdr/0.9.5/\(name).json"))
    }

    static func state() throws -> HerdrState {
        try #require(HerdrState.parse(workspaces: fixture("workspace-list"), panes: fixture("pane-list"), agents: fixture("agent-list")))
    }

    static func session(_ id: String, agent: AgentKind = .claudeCode, project: String? = "/Users/dev/code/orbit",
                        status: Session.Status = .idle) -> Session {
        Session(id: id, agent: agent, title: "Synthetic", projectPath: project, lastActive: Date(), sizeBytes: 1,
                status: status, expiresAt: nil, transcriptURL: URL(fileURLWithPath: "/tmp/\(id).jsonl"))
    }

    // MARK: Parsing

    @Test("parses workspaces, panes and agents; keeps session ids, never paths or titles")
    func parse() throws {
        let state = try Self.state()
        #expect(state.workspaces.map(\.label) == ["~", "orbit"])
        #expect(state.panes.map(\.id) == ["w1:p1", "w2:p1", "w2:p2", "w2:p3"])
        #expect(state.agents.map(\.kind) == ["claude", "codex", "claude"])
        #expect(state.agents.map(\.sessionID) == ["0f2c9a10-1111-4111-8111-111111111111", nil, nil])
        #expect(state.agents.first?.name == "orbit" && state.agents.first?.status == "working")
    }

    @Test("reads the shell pid and a created tab's pane; anything else is nil")
    func smallResponses() throws {
        #expect(HerdrState.shellPID(fromProcessInfo: try Self.fixture("pane-process-info")) == 400)
        #expect(HerdrState.rootPaneID(fromCreated: try Self.fixture("tab-created")) == "w2:p4")
        #expect(HerdrState.parse(workspaces: Data("not json".utf8), panes: Data(), agents: Data()) == nil)
        #expect(HerdrState.shellPID(fromProcessInfo: Data("{}".utf8)) == nil)
    }

    @Test("a fixture home never runs the real herdr")
    func customHome() {
        let home = URL(fileURLWithPath: "/tmp/domovy-herdr-\(UUID().uuidString)")
        let client = HerdrClient.at(home: home, isCustomHome: true, environment: [:])
        #expect(client.executable == nil && !client.mayBeRunning && client.state() == nil)
    }

    // MARK: Live sessions

    @Test("maps a session to its pane by session id, else by kind and folder when only one fits")
    func placement() throws {
        let state = try Self.state()
        let exact = try #require(state.placement(of: Self.session("0F2C9A10-1111-4111-8111-111111111111")))
        #expect(exact.paneID == "w2:p1" && exact.workspaceLabel == "orbit" && exact.agentName == "orbit")
        #expect(exact.liveReason == "Live in Herdr: orbit, pane w2:p1.")

        // One Codex agent in the folder and no session id: a live Codex session there is it.
        #expect(state.placement(of: Self.session("thread-1", agent: .codex, status: .live))?.paneID == "w2:p2")
        // Not live: the folder alone says nothing.
        #expect(state.placement(of: Self.session("thread-1", agent: .codex)) == nil)
        // Two Claude agents there, one reporting another session: only the other could match, and it does.
        #expect(state.placement(of: Self.session("other", status: .live))?.paneID == "w2:p3")
        // Another folder, or an agent Herdr does not know.
        #expect(state.placement(of: Self.session("thread-1", agent: .codex, project: "/Users/dev/elsewhere", status: .live)) == nil)
        #expect(state.placement(of: Self.session("x", agent: .aider, status: .live)) == nil)
    }

    @Test("a plan for a session running in Herdr is blocked and says where")
    func liveReason() throws {
        let session = Self.session("0f2c9a10-1111-4111-8111-111111111111")
        let plan = Plan(agent: .claudeCode, sessionID: session.id, action: .delete, destination: .trash, moves: [], indexEdits: [],
                        liveCheck: LiveCheckResult(isLive: false, reasons: [], checkedSignals: ["sessions/*.json"], openHandles: .clear))
        let marked = try Self.state().markingLive(plan, for: session)
        #expect(marked.liveCheck.isLive)
        #expect(marked.liveCheck.reasons == ["Live in Herdr: orbit, pane w2:p1."])
        #expect(marked.liveCheck.checkedSignals == ["sessions/*.json", "Herdr agent list"])
        #expect(HerdrState.empty.markingLive(plan, for: session).liveCheck.isLive == false)
    }

    // MARK: Resume

    @Test("resumes in a new tab of the workspace working in the folder, else a new workspace")
    func resume() throws {
        let state = try Self.state()
        let command = ResumeCommand(agent: .claudeCode, executable: "claude", arguments: ["--resume", "5e1d0000-aaaa"], directory: "/Users/dev/code/orbit")
        let plan = try #require(HerdrResume.plan(for: command, sessionID: "5E1D0000-aaaa", in: state))
        #expect(plan.paneArguments == ["tab", "create", "--workspace", "w2", "--cwd", "/Users/dev/code/orbit", "--label", "resume-5e1d0000", "--focus"])
        #expect(plan.startArguments(pane: "w2:p4") == ["agent", "start", "resume-5e1d0000", "--kind", "claude", "--pane", "w2:p4", "--", "--resume", "5e1d0000-aaaa"])

        let elsewhere = ResumeCommand(agent: .codex, executable: "codex", arguments: ["resume", "t1"], directory: "/Users/dev/code/new-thing")
        let fresh = try #require(HerdrResume.plan(for: elsewhere, sessionID: "t1", in: state))
        #expect(fresh.paneArguments == ["workspace", "create", "--cwd", "/Users/dev/code/new-thing", "--label", "new-thing", "--focus"])
        #expect(fresh.startArguments(pane: "w3:p1").prefix(5) == ["agent", "start", "resume-t1", "--kind", "codex"])

        let aider = ResumeCommand(agent: .aider, executable: "aider", arguments: [], directory: "/Users/dev/code/orbit")
        #expect(HerdrResume.plan(for: aider, sessionID: "a", in: state) == nil)
        #expect(HerdrResume.focusArguments(pane: "w2:p1") == ["agent", "focus", "w2:p1"])
    }

    @Test("agent names are valid for Herdr and unique among live agents")
    func names() {
        #expect(HerdrResume.uniqueName(for: "AB-12_cd-34ef", taken: []) == "resume-ab12cd34")
        #expect(HerdrResume.uniqueName(for: "ab12cd34", taken: ["resume-ab12cd34", "resume-ab12cd34-2"]) == "resume-ab12cd34-3")
    }

    // MARK: Processes

    /// launchd, the Herdr server, two pane shells: Claude Code with an MCP server in one, a
    /// bare MCP-looking script in the other; plus a real orphan.
    static let processes: [RawProcess] = [
        ProcessTable.p(1, 0, "launchd", path: "/sbin/launchd", uid: 0),
        ProcessTable.p(300, 1, "herdr", path: "/opt/homebrew/bin/herdr"),
        ProcessTable.p(400, 300, "zsh", path: "/bin/zsh"),
        ProcessTable.p(410, 400, "claude"),
        ProcessTable.p(420, 410, "node"),
        ProcessTable.p(500, 300, "zsh", path: "/bin/zsh"),
        ProcessTable.p(510, 500, "node"),
        ProcessTable.p(600, 1, "node"),
    ]

    static let arguments: [Int32: [String]] = [
        420: ["node", "/x/node_modules/@scope/mcp-files/index.js"],
        510: ["node", "mcp_server.js"],
        600: ["node", "/x/node_modules/@scope/mcp-left/index.js"],
    ]

    @Test("labels agent trees with their pane; nothing below Herdr is an orphan")
    func processes() throws {
        let source = FixedProcessSource(Self.processes, arguments: Self.arguments)
        let placement = try #require(try Self.state().placement(ofPane: "w2:p1"))
        let map = HerdrProcessMap(shells: [400: placement])
        let report = ProcessAnalyzer(source: source, sessions: nil).analyze(.init(processes: Self.processes, herdr: map)).report
        let group = try #require(report.groups.first { $0.root.pid == 410 })
        #expect(group.herdr?.title == "orbit, pane w2:p1")
        #expect(report.orphans.map(\.pid) == [600])

        // Herdr itself reparented to launchd, remembered as an agent's: still not an orphan.
        let remembered = [Self.processes[1].key: AgentKind.claudeCode]
        let again = ProcessAnalyzer(source: source, sessions: nil).analyze(.init(processes: Self.processes, remembered: remembered)).report
        #expect(!again.orphans.contains { $0.pid == 300 })
        #expect(again.groups.first { $0.root.pid == 410 }?.herdr == nil)
    }

    // MARK: Disk

    @Test("finds the worktree folder in Herdr's config, else the default")
    func worktreeFolder() throws {
        #expect(HerdrWorktrees.directory(inConfig: "[ui]\ndirectory = \"x\"\n[worktrees]\ndirectory = \"~/trees\" # mine\n") == "~/trees")
        #expect(HerdrWorktrees.directory(inConfig: "[theme]\nname = \"a\"\n") == nil)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-herdr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(HerdrWorktrees.folder(home: home).path == home.appendingPathComponent(".herdr/worktrees").path)
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".config/herdr"), withIntermediateDirectories: true)
        try Data("[worktrees]\ndirectory = \"~/trees\"\n".utf8).write(to: home.appendingPathComponent(".config/herdr/config.toml"))
        #expect(HerdrWorktrees.folder(home: home).path == home.appendingPathComponent("trees").path)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("trees/orbit/feature-x"), withIntermediateDirectories: true)
        let scanner = LeftoverScanner(home: home)
        #expect(scanner.owner(of: home.appendingPathComponent("trees/orbit/feature-x").resolvingSymlinksInPath(), used: []) == .herdr)
    }

    @Test("measures logs as safe, snapshots with consequences, state and the app as keep")
    func footprint() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-herdr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let fm = FileManager.default
        for folder in [".config/herdr/session-snapshots", ".config/herdr-app/mods", ".local/bin"] {
            try fm.createDirectory(at: home.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in [".config/herdr/herdr-server.log", ".config/herdr/config.toml", ".config/herdr/session.json",
                     ".config/herdr/session-snapshots/session-1.json", ".config/herdr-app/mods/a.js", ".local/bin/herdr.123.old", ".local/bin/agy"] {
            try Data(repeating: 1, count: 5_000).write(to: home.appendingPathComponent(file))
        }
        let footprint = try await HerdrFootprint(home: home).footprint()
        let byName = Dictionary(uniqueKeysWithValues: footprint.categories.map { ($0.name, $0.disposition) })
        #expect(byName == ["Logs": .safe, "Layout snapshots": .consequences, "Old binaries": .safe, "Layout and settings": .keep, "Herdr app": .keep])
        let empty = home.appendingPathComponent("empty", isDirectory: true)
        await #expect(throws: AdapterError.self) { try await HerdrFootprint(home: empty).footprint() }
    }
}
