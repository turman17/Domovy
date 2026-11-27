@testable import DomovyCore
import Foundation
import Testing

@Suite("domo install, update and the CLI fallback")
struct InstallFlowTests {
    typealias Home = ConnectTests.Home
    typealias IDs = FixtureHome.ClaudeCode

    /// A home with Claude Code, Codex and Cursor installed.
    private func threeAgents() throws -> Home {
        let home = try Home()
        try home.write(".claude.json", "{}\n")
        try home.mkdir(".codex")
        try home.mkdir(".cursor")
        return home
    }

    // MARK: Skill

    @Test("the installed skill names the registered domo, with --root only for a custom home")
    func installationLine() {
        let plain = DomovySkill.skillFile(command: ["/Users/dev/.local/bin/domo", "mcp"])
        #expect(plain.hasPrefix(DomovySkill.template))
        #expect(plain.contains("## Installation-specific command"))
        #expect(plain.contains("`/Users/dev/.local/bin/domo`"))
        #expect(!plain.contains("--root '") && !plain.contains("add `--root"))

        let custom = DomovySkill.skillFile(command: ["/Applications/My Apps/domo", "mcp", "--root", "/tmp/fixture home"])
        #expect(custom.contains("`'/Applications/My Apps/domo'`"))
        #expect(custom.contains("add `--root '/tmp/fixture home'` to every command"))
        #expect(DomovySkill.files(command: ["/x/domo", "mcp"]).keys.sorted() == ["SKILL.md", "references.md"])
    }

    // MARK: Picker

    @Test("the picker starts with every detected agent checked; space toggles, enter applies")
    func picker() throws {
        let home = try threeAgents()
        let plan = home.connector().plan(.connect, command: ConnectTests.command)
        var picker = InstallPicker(plan: plan)
        #expect(picker.rows.map(\.agent) == [.claudeCode, .codex, .cursor])
        // Without a terminal, `domo install -y` applies exactly this default.
        #expect(picker.chosen == [.claudeCode, .codex, .cursor])
        #expect(picker.lines(home: home.home).contains { $0.contains("[x] Codex") })
        #expect(picker.lines(home: home.home).contains { $0.contains("Install the domovy skill") })

        #expect(picker.handle(.down) == nil)
        #expect(picker.handle(.toggle) == nil)
        #expect(picker.chosen == [.claudeCode, .cursor])
        #expect(picker.lines(home: home.home).contains { $0.hasPrefix("> [ ] Codex") })
        #expect(picker.handle(.up) == nil)
        #expect(picker.handle(.up) == nil) // wraps to the last row
        #expect(picker.handle(.toggle) == nil)
        #expect(picker.handle(.apply) == .apply([.claudeCode]))
        _ = picker.handle(.clear)
        #expect(picker.changing.isEmpty)
        _ = picker.handle(.all)
        #expect(picker.handle(.cancel) == .cancel)

        #expect(InstallPicker.key(for: [0x20]) == .toggle)
        #expect(InstallPicker.key(for: [0x0D]) == .apply)
        #expect(InstallPicker.key(for: [0x1B, 0x5B, 0x42]) == .down)
        #expect(InstallPicker.key(for: [0x71]) == .cancel)
        #expect(InstallPicker.key(for: [0x7A]) == nil)
    }

    // MARK: Refresh

    @Test("refresh re-registers and rewrites the skill only for agents that have Domovy")
    func refresh() throws {
        let home = try threeAgents()
        let connector = home.connector()
        let old = ["/opt/homebrew/Cellar/domo/0.1/bin/domo", "mcp"]
        _ = connector.execute(connector.plan(.connect, command: old, agents: [.claudeCode, .codex]))
        #expect(Set(connector.connected()) == [.claudeCode, .codex])
        #expect(home.read(".claude/skills/domovy/SKILL.md")?.contains(old[0]) == true)

        let new = ["/Users/dev/.local/bin/domo", "mcp"]
        let plan = connector.refreshPlan(command: new)
        #expect(plan.agents.map(\.agent) == [.claudeCode, .codex])
        #expect(plan.agents.allSatisfy { $0.state == .willChange })
        for result in connector.execute(plan) { #expect(result.outcome == .changed, "\(result.agent): \(result.outcome)") }

        for skill in [".claude/skills/domovy/SKILL.md", ".agents/skills/domovy/SKILL.md"] {
            let text = try #require(home.read(skill))
            #expect(text == DomovySkill.skillFile(command: new), "\(skill)")
            #expect(!text.contains(old[0]))
        }
        #expect(home.read(".agents/skills/domovy/references.md") == DomovySkill.files(command: new)["references.md"])
        #expect(try connector.registered(.claudeCode, in: Data(contentsOf: ConnectAgent.claudeCode.configFile(home: home.home))) == new)
        #expect(try connector.registered(.codex, in: Data(contentsOf: ConnectAgent.codex.configFile(home: home.home))) == new)
        // Cursor was never connected and stays that way; a second refresh has nothing to do.
        #expect(!home.exists(".cursor/mcp.json"))
        #expect(connector.refreshPlan(command: new).agents.allSatisfy { $0.state == .upToDate })
    }

    // MARK: The built domo

    /// Runs the `domo` `swift test` built, with stdin from `input` (never a terminal).
    struct Run {
        let status: Int32
        let output: String
        var json: JSONValue? { try? JSONDecoder().decode(JSONValue.self, from: Data(output.utf8)) }
    }

    /// `domo` beside the test bundle, else in the package's `.build/debug` (`swift test` builds both).
    static var builtDomo: URL? {
        if let found = MCPStdioTests.Client.builtDomo() { return found }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidate = repo.appendingPathComponent(".build/debug/domo")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate.resolvingSymlinksInPath() : nil
    }

    static func domo(_ arguments: [String], input: String = "", environment: [String: String] = [:]) throws -> Run {
        let executable = try #require(builtDomo, "swift test builds domo")
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        stdin.fileHandleForWriting.write(Data(input.utf8))
        try stdin.fileHandleForWriting.close()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    @Test("domo with piped stdin and no arguments is the MCP server")
    func pipedServer() throws {
        let fixture = try FixtureHome()
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_sessions","arguments":{"agent":"claude-code"}}}"#,
        ].joined(separator: "\n") + "\n"
        let run = try Self.domo([], input: input, environment: ["DOMOVY_ROOT": fixture.home.path])
        #expect(run.status == 0)
        let replies = run.output.split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        #expect(replies.count == 2)
        #expect(replies.first?["result"]?["serverInfo"]?["name"] == "domovy")
        let ids = replies.last?["result"]?["structuredContent"]?["sessions"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(ids.contains(IDs.idle))
    }

    @Test("domo install without a terminal asks for --yes, then connects every agent; update rewrites the path")
    func installCommand() throws {
        let home = try threeAgents()
        let root = ["--root", home.home.path]
        let before = home.snapshot()
        let refused = try Self.domo(["install"] + root)
        #expect(refused.status != 0)
        #expect(home.snapshot() == before)

        let installed = try Self.domo(["install", "-y"] + root)
        #expect(installed.status == 0, "\(installed.output)")
        let domo = try #require(Self.builtDomo).path
        let skill = try #require(home.read(".claude/skills/domovy/SKILL.md"))
        #expect(skill.contains(domo))
        #expect(skill.contains("--root \(ConnectManual.quoted(home.home.path))"))
        #expect(home.read(".cursor/mcp.json")?.contains("domovy") == true)

        let moved = home.home.deletingLastPathComponent().appendingPathComponent("bin/domo").path
        let updated = try Self.domo(["update", "--command", moved] + root)
        #expect(updated.status == 0, "\(updated.output)")
        for path in [".claude/skills/domovy/SKILL.md", ".agents/skills/domovy/SKILL.md"] {
            #expect(home.read(path)?.contains("`\(moved)`") == true, "\(path)")
        }
        #expect(home.read(".cursor/mcp.json")?.contains(moved) == true)
    }

    @Test("CLI fallback: ls --json, rm by filters dry run vs execute, a changed plan refused, undo by id")
    func cliFallback() throws {
        let fixture = try FixtureHome()
        let root = ["--root", fixture.home.path]
        let ls = try Self.domo(["ls", "--json", "--agent", "claude-code"] + root)
        #expect(ls.status == 0)
        let listed = ls.json?["sessions"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(listed.contains(IDs.idle) && listed.contains(IDs.expiring))

        // --older 20d picks the 26-day-old session, not the 2-day-old one; a dry run moves nothing.
        let expiring = fixture.transcript(IDs.expiring, project: "-Users-dev-code-landing-site")
        let dry = try Self.domo(["rm", "--older", "20d", "--agent", "claude-code", "--to", "quarantine", "--dry-run", "--json"] + root)
        #expect(dry.status == 0, "\(dry.output)")
        let plan = try #require(dry.json?["plan"])
        #expect(dry.json?["dry_run"] == .bool(true))
        let planned = plan["plans"]?.arrayValue?.compactMap { $0["session_id"]?.stringValue } ?? []
        #expect(planned.contains(IDs.expiring))
        #expect(!planned.contains(IDs.idle))
        #expect(plan["plan_token"] == nil)
        let digest = try #require(plan["plan_digest"]?.stringValue)
        #expect(FileManager.default.fileExists(atPath: expiring.path))

        // Without --yes and without a terminal nothing changes.
        let unconfirmed = try Self.domo(["rm", IDs.expiring, "--to", "quarantine"] + root)
        #expect(unconfirmed.status != 0)
        #expect(FileManager.default.fileExists(atPath: expiring.path))

        // A digest from another plan is refused.
        let stale = try Self.domo(["rm", "--older", "20d", "--agent", "claude-code", "--to", "quarantine", "-y", "--if-plan", "0000000000000000", "--json"] + root)
        #expect(stale.status != 0)
        #expect(stale.json?["result"]?["changed"] == .bool(false))
        #expect(FileManager.default.fileExists(atPath: expiring.path))

        let done = try Self.domo(["rm", "--older", "20d", "--agent", "claude-code", "--to", "quarantine", "-y", "--if-plan", digest, "--json"] + root)
        #expect(done.status == 0, "\(done.output)")
        let result = try #require(done.json?["result"])
        #expect(result["changed"] == .bool(true))
        let undo = try #require(result["undo_id"]?.stringValue)
        #expect(!FileManager.default.fileExists(atPath: expiring.path))

        let undone = try Self.domo(["undo", undo, "--json"] + root)
        #expect(undone.status == 0, "\(undone.output)")
        #expect(undone.json?["undone"]?.arrayValue?.contains { $0["session_id"]?.stringValue == IDs.expiring } == true)
        #expect(FileManager.default.fileExists(atPath: expiring.path))
    }

    @Test("the CLI refuses a session written to in the last 10 minutes, like the MCP tools")
    func recentRefused() throws {
        let fixture = try FixtureHome()
        try fixture.setTranscriptDate(IDs.idle, project: "-Users-dev-code-orbit-api", Date().addingTimeInterval(-60))
        let run = try Self.domo(["rm", IDs.idle, "-y", "--to", "quarantine", "--json", "--root", fixture.home.path])
        #expect(run.status != 0)
        #expect(run.json?["plan"]?["blocked"]?.arrayValue?.isEmpty == false)
        #expect(FileManager.default.fileExists(atPath: fixture.transcript(IDs.idle, project: "-Users-dev-code-orbit-api").path))
    }
}
