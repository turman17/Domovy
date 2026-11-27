@testable import DomovyCore
import Foundation
import Testing

@Suite("Connect agents: skills, manual steps, domo link")
struct ConnectSkillsTests {
    typealias Home = ConnectTests.Home
    static let command = ConnectTests.command

    /// A home where every agent is detected, from its marker paths.
    private func everyAgent() throws -> Home {
        let home = try Home()
        for agent in ConnectAgent.allCases {
            for marker in agent.markers {
                if marker.hasSuffix(".json") { try home.write(marker, "{}\n") } else { try home.mkdir(marker) }
            }
        }
        return home
    }

    /// Where each agent's skill goes, relative to home; `nil` for none.
    static let expectedSkills: [ConnectAgent: String?] = [
        .claudeCode: ".claude/skills", .antigravity: ".gemini/config/skills", .cline: ".cline/skills",
        .continueDev: ".continue/skills", .kiro: ".kiro/skills", .kimi: ".kimi/skills",
        .claudeDesktop: nil, .amazonQ: nil,
        .codex: ".agents/skills", .gemini: ".agents/skills", .qwen: ".agents/skills", .cursor: ".agents/skills",
        .openCode: ".agents/skills", .copilot: ".agents/skills", .zed: ".agents/skills", .vsCode: ".agents/skills",
        .crush: ".agents/skills", .kilo: ".agents/skills", .rooCode: ".agents/skills", .auggie: ".agents/skills",
        .factoryDroid: ".agents/skills",
    ]

    @Test("every agent's skill goes to a skills folder (its own or the shared one), never into a shared rules file")
    func skillFolders() throws {
        #expect(Set(Self.expectedSkills.keys) == Set(ConnectAgent.allCases))
        let home = try everyAgent()
        let before = home.snapshot()
        let connector = home.connector()
        #expect(Set(connector.detected()) == Set(ConnectAgent.allCases))

        let plan = connector.plan(.connect, command: Self.command)
        for item in plan.agents { #expect(item.state == .willChange, "\(item.agent): \(item.state)") }
        for result in connector.execute(plan) { #expect(result.outcome == .changed, "\(result.agent): \(result.outcome)") }

        for (agent, folder) in Self.expectedSkills {
            #expect(agent.skillsDirectory(home: home.home)?.path == folder.map { home.home.appendingPathComponent($0).path }, "\(agent)")
            if let folder { #expect(home.read("\(folder)/domovy/SKILL.md") == DomovySkill.skillFile(command: Self.command), "\(agent)") }
        }
        // Only SKILL.md files and MCP configs were written: no instructions file anyone else reads.
        let shared = ["CLAUDE.md", "AGENTS.md", "GEMINI.md", "QWEN.md", ".cursorrules", "global_rules.md", ".goosehints"]
        for path in home.snapshot().keys where before[path] == nil {
            #expect(!shared.contains(URL(fileURLWithPath: path).lastPathComponent), "\(path)")
            #expect(!path.contains("/rules/") && !path.contains("/steering/"), "\(path)")
        }

        // Disconnect gives back the home exactly: files, and the folders connect made.
        for result in connector.execute(connector.plan(.disconnect, command: [])) {
            #expect(result.outcome == .changed, "\(result.agent): \(result.outcome)")
        }
        #expect(home.snapshot() == before)
    }

    @Test("disconnect keeps a skills folder that existed, and a folder the user put files in")
    func keepsUsersFolders() throws {
        let home = try Home()
        try home.write(".kimi/mcp.json", "{\"mcpServers\": {}}\n")
        try home.write(".cline/skills/mine/SKILL.md", "---\nname: mine\ndescription: x\n---\n")
        try home.mkdir(".cline/data/settings")
        try home.mkdir(".kiro")
        let connector = home.connector()
        let agents: [ConnectAgent] = [.kimi, .cline, .kiro]
        _ = connector.execute(connector.plan(.connect, command: Self.command, agents: agents))
        #expect(home.exists(".kimi/skills/domovy/SKILL.md"))
        #expect(home.exists(".cline/skills/domovy/SKILL.md"))
        #expect(home.exists(".kiro/skills/domovy/SKILL.md"))
        try home.write(".kiro/skills/notes.txt", "mine")
        _ = connector.execute(connector.plan(.disconnect, command: [], agents: agents))
        #expect(!home.exists(".kimi/skills"))
        #expect(home.exists(".cline/skills/mine/SKILL.md"))
        #expect(!home.exists(".cline/skills/domovy"))
        #expect(home.read(".kiro/skills/notes.txt") == "mine")
        #expect(!home.exists(".kiro/skills/domovy"))
        #expect(!home.exists(".kiro/settings"), "the settings folder connect made for mcp.json goes too")
    }

    @Test("each step has a copyable manual form: the agent's command, a config snippet, or the skill command")
    func manualSteps() throws {
        let home = try Home()
        try home.write(".cursor/mcp.json", "{\"mcpServers\": {\"a\": {\"command\": \"y\"}}}")
        try home.write(".codex/config.toml", "model = \"gpt-5\"\n")
        let stub = home.home.appendingPathComponent("bin/claude")
        try home.write("bin/claude", "#!/bin/sh\n")
        try home.mkdir(".claude")
        let connector = AgentConnector(home: home.home, isCustomHome: true, storeRoot: home.store, processes: FixedProcessLister([]),
                                       checksRunningApps: false, locateCLI: { $0 == "claude" ? stub : nil })
        let plan = connector.plan(.connect, command: Self.command, agents: [.claudeCode, .cursor, .codex])
        func steps(_ agent: ConnectAgent) -> [ManualStep] {
            plan.agents.first { $0.agent == agent }?.manualSteps(home: home.home, domo: Self.command[0]) ?? []
        }

        let claude = steps(.claudeCode)
        #expect(claude.first?.isShellCommand == true)
        #expect(claude.first?.text == "claude mcp add --transport stdio --scope user domovy -- /opt/homebrew/bin/domo mcp")
        let skill = try #require(claude.last)
        #expect(skill.text.contains("/opt/homebrew/bin/domo connect --print-skill > "))
        #expect(skill.text.contains(".claude/skills/domovy/SKILL.md && "))
        #expect(skill.text.hasSuffix(".claude/skills/domovy/references.md"))

        let cursor = try #require(steps(.cursor).first)
        #expect(!cursor.isShellCommand)
        let snippet = try JSONSerialization.jsonObject(with: Data(cursor.text.utf8)) as? [String: Any]
        let entry = (snippet?["mcpServers"] as? [String: Any])?["domovy"] as? [String: Any]
        #expect(entry?["command"] as? String == "/opt/homebrew/bin/domo")
        #expect(entry?["args"] as? [String] == ["mcp"])

        #expect(steps(.codex).first?.text == "[mcp_servers.domovy]\ncommand = \"/opt/homebrew/bin/domo\"\nargs = [\"mcp\"]")

        let script = plan.manualScript(home: home.home, agents: [.cursor, .claudeCode])
        #expect(script.contains("# Claude Code\nclaude mcp add"))
        #expect(script.contains("#   {"))
        #expect(!script.contains("# Codex"))
    }

    @Test("shell paths quote spaces and quotes")
    func quoting() {
        #expect(ConnectManual.quoted("/opt/homebrew/bin/domo") == "/opt/homebrew/bin/domo")
        #expect(ConnectManual.quoted("/Applications/My Apps/Domovy.app") == "'/Applications/My Apps/Domovy.app'")
        #expect(ConnectManual.quoted("it's") == "'it'\\''s'")
    }

    // MARK: domo link

    private func fakeApp(in home: Home) throws -> URL {
        let domo = home.home.deletingLastPathComponent().appendingPathComponent("Apps/Domovy.app/Contents/Helpers/domo")
        try FileManager.default.createDirectory(at: domo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: domo)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: domo.path)
        return domo
    }

    @Test("install links ~/.local/bin/domo to the app's domo, says when it is not on PATH, uninstall removes only that link")
    func linkRoundTrip() throws {
        let home = try Home()
        let bundled = try fakeApp(in: home)
        let local = home.home.appendingPathComponent(".local/bin").path

        let offPath = DomoCommandLink(home: home.home, isCustomHome: true, pathDirectories: ["/usr/bin"])
        #expect(offPath.status() == .notInstalled)
        let target = try offPath.install(bundled: bundled)
        #expect(target.link.path == local + "/domo")
        #expect(!target.onPath)
        #expect(target.pathAdvice?.contains(".local/bin") == true)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.link.path) == bundled.path)
        #expect(offPath.status() == .linked(target.link, onPath: false))

        let onPath = DomoCommandLink(home: home.home, isCustomHome: true, pathDirectories: [local, "/usr/bin"])
        #expect(onPath.status() == .linked(target.link, onPath: true))
        // Installing again points the same link again.
        #expect(try onPath.install(bundled: bundled).onPath)
        #expect(MCPRegistration.installedDomo(linked: target.link, environment: [:]) == target.link)

        #expect(try onPath.uninstall() == [target.link])
        #expect(!FileManager.default.fileExists(atPath: target.link.path))
        #expect(try onPath.uninstall().isEmpty)
    }

    @Test("a domo Domovy did not make is never replaced or removed")
    func foreignDomo() throws {
        let home = try Home()
        let bundled = try fakeApp(in: home)
        try home.write(".local/bin/domo", "#!/bin/sh\necho mine\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.home.appendingPathComponent(".local/bin/domo").path)
        let local = home.home.appendingPathComponent(".local/bin").path
        let link = DomoCommandLink(home: home.home, isCustomHome: true, pathDirectories: [local])
        #expect(link.status() == .otherOnPath(home.home.appendingPathComponent(".local/bin/domo")))
        #expect(throws: DomoCommandLink.LinkError.self) { try link.install(bundled: bundled) }
        #expect(try link.uninstall().isEmpty)
        #expect(home.read(".local/bin/domo") == "#!/bin/sh\necho mine\n")
        #expect(throws: DomoCommandLink.LinkError.self) { try link.install(bundled: nil) }
    }

    @Test("the registered domo is the path it was run by, not where a link points")
    func invokedPath() throws {
        let home = try Home()
        let bundled = try fakeApp(in: home)
        let bin = home.home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("domo"), withDestinationURL: bundled)
        #expect(MCPRegistration.invokedExecutable(arguments: ["domo", "connect"], environment: ["PATH": bin.path])?.path == bin.appendingPathComponent("domo").path)
        #expect(MCPRegistration.invokedExecutable(arguments: [bin.path + "/domo"], environment: [:])?.path == bin.appendingPathComponent("domo").path)
    }
}
