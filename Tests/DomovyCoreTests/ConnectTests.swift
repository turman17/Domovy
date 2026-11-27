@testable import DomovyCore
import Foundation
import Testing

@Suite("Connect agents")
struct ConnectTests {
    /// A temp home with a few agents' folders and config files in different shapes.
    final class Home: Sendable {
        let home: URL
        let store: URL

        init() throws {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-connect-\(UUID().uuidString)", isDirectory: true)
            home = base.appendingPathComponent("home", isDirectory: true)
            store = base.appendingPathComponent("store", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: home.deletingLastPathComponent()) }

        func write(_ relative: String, _ text: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func mkdir(_ relative: String) throws {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(relative), withIntermediateDirectories: true)
        }

        func read(_ relative: String) -> String? {
            (try? Data(contentsOf: home.appendingPathComponent(relative))).map { String(decoding: $0, as: UTF8.self) }
        }

        func exists(_ relative: String) -> Bool {
            FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path)
        }

        /// Every file under the home with its bytes, to prove nothing changed.
        func snapshot() -> [String: Data] {
            var result: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)
            while let url = enumerator?.nextObject() as? URL {
                if let data = try? Data(contentsOf: url) { result[url.path] = data } else { result[url.path] = Data() }
            }
            return result
        }

        func connector(running: [RunningProcess] = []) -> AgentConnector {
            AgentConnector(home: home, isCustomHome: true, storeRoot: store, processes: FixedProcessLister(running), checksRunningApps: true)
        }
    }

    static let command = ["/opt/homebrew/bin/domo", "mcp"]

    static let originals: [String: String] = [
        // Claude Code: other servers, 2-space indent, no trailing newline.
        ".claude.json": "{\n  \"numStartups\": 3,\n  \"mcpServers\": {\n    \"other\": {\n      \"command\": \"x\"\n    }\n  }\n}",
        // Codex: TOML without a trailing newline, with comments and other tables.
        ".codex/config.toml": "# my settings\nmodel = \"gpt-5\"\n\n[mcp_servers.other]\ncommand = \"x\"  # keep\n\n[projects.\"/Users/dev/code\"]\ntrust_level = \"trusted\"",
        // Gemini: an empty object; mcpServers must be created and removed again.
        ".gemini/settings.json": "{\n}\n",
        // Cursor: single-line JSON.
        ".cursor/mcp.json": "{\"mcpServers\": {\"a\": {\"command\": \"y\"}}}",
        // OpenCode: JSONC with comments, flat `mcp`, tab indents.
        ".config/opencode/opencode.json": "{\n\t\"$schema\": \"https://opencode.ai/config.json\",\n\t// servers\n\t\"mcp\": {\n\t\t\"fetch\": {\n\t\t\t\"type\": \"local\",\n\t\t\t\"command\": [\"fetch\"],\n\t\t\t\"enabled\": true\n\t\t},\n\t},\n}\n",
        // Zed: comments, older "source": "custom" entries.
        ".config/zed/settings.json": "// Zed settings\n{\n  \"theme\": \"One Dark\", // dark\n  \"context_servers\": {\n    \"git\": { \"source\": \"custom\", \"command\": \"git-mcp\", \"args\": [] }\n  }\n}\n",
        // VS Code: an empty servers object.
        "Library/Application Support/Code/User/mcp.json": "{\n  \"servers\": {},\n  \"inputs\": []\n}\n",
    ]

    private func prepare() throws -> Home {
        let home = try Home()
        for (path, text) in Self.originals { try home.write(path, text) }
        try home.mkdir(".claude")
        try home.mkdir("Library/Application Support/Claude") // Claude Desktop without a config file
        try home.mkdir(".gemini/config") // Antigravity without a config file
        return home
    }

    @Test("without a domo command, connect refuses each agent instead of crashing, and changes nothing")
    func missingCommand() async throws {
        let home = try prepare()
        let before = home.snapshot()
        let connector = home.connector()
        let plan = connector.plan(.connect, command: [])
        #expect(!plan.agents.isEmpty)
        for item in plan.agents { #expect(item.state == .refused(AgentConnector.missingCommand), "\(item.agent): \(item.state)") }
        _ = connector.execute(plan)
        #expect(home.snapshot() == before)
    }

    @Test("connect adds the server everywhere, again changes nothing, disconnect restores every byte")
    func roundTrip() async throws {
        let home = try prepare()
        let connector = home.connector()
        #expect(Set(connector.detected()) == [.claudeCode, .codex, .gemini, .cursor, .openCode, .zed, .vsCode, .claudeDesktop, .antigravity])

        let plan = connector.plan(.connect, command: Self.command)
        for item in plan.agents { #expect(item.state == .willChange, "\(item.agent): \(item.state)") }
        let results = connector.execute(plan)
        for result in results { #expect(result.outcome == .changed, "\(result.agent): \(result.outcome)") }

        // Every config now names the server, in the agent's own shape, and still parses.
        for agent in connector.detected() {
            let data = try Data(contentsOf: agent.configFile(home: home.home))
            #expect(try connector.registered(agent, in: data) == Self.command, "\(agent)")
            if !agent.isTOML {
                #expect((try? JSONSerialization.jsonObject(with: Data(JSONCEditor.strip([UInt8](data))))) != nil, "\(agent) is still JSON")
            }
        }
        #expect(home.read(".codex/config.toml")?.hasSuffix("trust_level = \"trusted\"\n\n[mcp_servers.domovy]\ncommand = \"/opt/homebrew/bin/domo\"\nargs = [\"mcp\"]\n") == true)
        #expect(home.read(".config/zed/settings.json")?.contains("\"domovy\": {\n      \"source\": \"custom\"") == true)
        #expect(home.read(".config/opencode/opencode.json")?.contains("\"command\": [\"/opt/homebrew/bin/domo\", \"mcp\"]") == true)
        #expect(home.read(".config/opencode/opencode.json")?.contains("// servers") == true)
        #expect(home.read("Library/Application Support/Claude/claude_desktop_config.json") != nil)
        // Skills: Claude Code's own folder, the shared one, Antigravity's.
        #expect(home.read(".claude/skills/domovy/SKILL.md") == DomovySkill.skillFile(command: Self.command))
        #expect(home.read(".agents/skills/domovy/SKILL.md") == DomovySkill.skillFile(command: Self.command))
        #expect(home.read(".gemini/config/skills/domovy/SKILL.md") == DomovySkill.skillFile(command: Self.command))
        // Backups of changed files.
        let backups = try FileManager.default.contentsOfDirectory(atPath: home.store.appendingPathComponent("Connect/Backups").path)
        #expect(backups.count == Self.originals.count)

        // Idempotent.
        let again = connector.plan(.connect, command: Self.command)
        for item in again.agents { #expect(item.state == .upToDate, "\(item.agent): \(item.state)") }

        // Disconnect: byte for byte.
        let undo = connector.plan(.disconnect, command: [])
        for result in connector.execute(undo) { #expect(result.outcome == .changed, "\(result.agent): \(result.outcome)") }
        for (path, text) in Self.originals { #expect(home.read(path) == text, "\(path)") }
        #expect(!home.exists("Library/Application Support/Claude/claude_desktop_config.json"))
        #expect(!home.exists(".gemini/config/mcp_config.json"))
        #expect(!home.exists(".claude/skills/domovy"))
        #expect(!home.exists(".agents/skills/domovy"))

        let none = connector.plan(.disconnect, command: [])
        for item in none.agents { #expect(item.state == .upToDate) }
    }

    @Test("the newer agents get the server in their own config shape, and disconnect restores every byte")
    func newerAgents() async throws {
        let home = try Home()
        let originals = [
            ".kimi/mcp.json": "{\"mcpServers\": {}}\n",
            ".config/crush/crush.json": "{\n  \"$schema\": \"https://charm.land/crush.json\",\n  \"mcp\": {}\n}\n",
            ".cline/data/settings/cline_mcp_settings.json": "{\n  \"mcpServers\": {}\n}",
            ".config/kilo/kilo.jsonc": "{\n  // mine\n  \"mcp\": {}\n}\n",
            ConnectAgent.rooSettings + "/settings/mcp_settings.json": "{\"mcpServers\":{}}",
        ]
        for (path, text) in originals { try home.write(path, text) }
        try home.mkdir(".continue")
        let agents: [ConnectAgent] = [.kimi, .crush, .cline, .kilo, .rooCode, .continueDev]
        let connector = home.connector()
        #expect(Set(connector.detected()).isSuperset(of: agents))
        for result in connector.execute(connector.plan(.connect, command: Self.command, agents: agents)) {
            #expect(result.outcome == .changed, "\(result.agent): \(result.outcome)")
        }
        for agent in agents {
            #expect(try connector.registered(agent, in: try Data(contentsOf: agent.configFile(home: home.home))) == Self.command, "\(agent)")
        }
        #expect(home.read(".config/crush/crush.json")?.contains("\"type\": \"stdio\"") == true)
        #expect(home.read(".config/kilo/kilo.jsonc")?.contains("\"command\": [\"/opt/homebrew/bin/domo\", \"mcp\"]") == true)
        #expect(home.read(".config/kilo/kilo.jsonc")?.contains("// mine") == true)
        #expect(home.read(".cline/data/settings/cline_mcp_settings.json")?.contains("\"disabled\": false") == true)
        #expect(home.read(".continue/mcpServers/domovy.json")?.contains("\"mcpServers\"") == true)

        for result in connector.execute(connector.plan(.disconnect, command: [], agents: agents)) {
            #expect(result.outcome == .changed, "\(result.agent): \(result.outcome)")
        }
        for (path, text) in originals { #expect(home.read(path) == text, "\(path)") }
        #expect(!home.exists(".continue/mcpServers/domovy.json"))
    }

    @Test("Auggie, Factory Droid, Kiro and Amazon Q get an mcpServers entry; settings around it survive disconnect")
    func lastBatch() async throws {
        let home = try Home()
        let originals = [
            ".augment/settings.json": "{\n  \"model\": \"synthetic\",\n  \"mcpServers\": {}\n}\n",
            ".factory/mcp.json": "{\"mcpServers\": {\"linear\": {\"type\": \"http\", \"url\": \"https://example.invalid/mcp\"}}}\n",
            ".kiro/settings/mcp.json": "{\n  \"mcpServers\": {}\n}\n",
            ".aws/amazonq/mcp.json": "{\"mcpServers\": {}}",
        ]
        for (path, text) in originals { try home.write(path, text) }
        let agents: [ConnectAgent] = [.auggie, .factoryDroid, .kiro, .amazonQ]
        let connector = home.connector()
        #expect(Set(connector.detected()).isSuperset(of: agents))
        for result in connector.execute(connector.plan(.connect, command: Self.command, agents: agents)) {
            #expect(result.outcome == .changed, "\(result.agent): \(result.outcome)")
        }
        for agent in agents {
            #expect(try connector.registered(agent, in: try Data(contentsOf: agent.configFile(home: home.home))) == Self.command, "\(agent)")
        }
        #expect(home.read(".factory/mcp.json")?.contains("\"type\": \"stdio\"") == true)
        #expect(home.read(".augment/settings.json")?.contains("\"model\": \"synthetic\"") == true)
        for result in connector.execute(connector.plan(.disconnect, command: [], agents: agents)) {
            #expect(result.outcome == .changed, "\(result.agent): \(result.outcome)")
        }
        for (path, text) in originals { #expect(home.read(path) == text, "\(path)") }
    }

    @Test("planning (dry run) changes nothing")
    func dryRun() async throws {
        let home = try prepare()
        let before = home.snapshot()
        _ = home.connector().plan(.connect, command: Self.command)
        #expect(home.snapshot() == before)
        #expect(!FileManager.default.fileExists(atPath: home.store.path))
    }

    @Test("a different command is updated in place; disconnect still removes it")
    func update() async throws {
        let home = try prepare()
        let connector = home.connector()
        _ = connector.execute(connector.plan(.connect, command: Self.command, agents: [.cursor, .codex]))
        let moved = ["/usr/local/bin/domo", "mcp"]
        let plan = connector.plan(.connect, command: moved, agents: [.cursor, .codex])
        #expect(plan.agents.allSatisfy { $0.state == .willChange })
        _ = connector.execute(plan)
        #expect(try connector.registered(.cursor, in: Data(contentsOf: ConnectAgent.cursor.configFile(home: home.home))) == moved)
        #expect(try connector.registered(.codex, in: Data(contentsOf: ConnectAgent.codex.configFile(home: home.home))) == moved)
        _ = connector.execute(connector.plan(.disconnect, command: [], agents: [.cursor, .codex]))
        #expect(home.read(".cursor/mcp.json") == Self.originals[".cursor/mcp.json"])
        #expect(home.read(".codex/config.toml") == Self.originals[".codex/config.toml"])
    }

    @Test("edits made after connect survive disconnect")
    func laterEdits() async throws {
        let home = try prepare()
        let connector = home.connector()
        _ = connector.execute(connector.plan(.connect, command: Self.command, agents: [.claudeCode, .codex]))
        // The user adds another server after ours.
        let claude = try #require(home.read(".claude.json"))
        try home.write(".claude.json", claude.replacingOccurrences(of: "\"mcp\"],\n      \"env\": {}\n    }", with: "\"mcp\"],\n      \"env\": {}\n    },\n    \"later\": {\"command\": \"z\"}"))
        try home.write(".codex/config.toml", try #require(home.read(".codex/config.toml")) + "\n[mcp_servers.later]\ncommand = \"z\"\n")
        _ = connector.execute(connector.plan(.disconnect, command: [], agents: [.claudeCode, .codex]))
        let claudeAfter = try #require(home.read(".claude.json"))
        #expect(!claudeAfter.contains("domovy"))
        #expect(claudeAfter.contains("\"later\""))
        #expect((try? JSONSerialization.jsonObject(with: Data(claudeAfter.utf8))) != nil)
        let toml = try #require(home.read(".codex/config.toml"))
        #expect(!toml.contains("domovy"))
        #expect(toml.contains("[mcp_servers.later]"))
        #expect(toml.contains("[mcp_servers.other]"))
    }

    @Test("a shared skill folder stays while another connected agent reads it")
    func sharedSkill() async throws {
        let home = try prepare()
        let connector = home.connector()
        _ = connector.execute(connector.plan(.connect, command: Self.command, agents: [.cursor, .zed]))
        _ = connector.execute(connector.plan(.disconnect, command: [], agents: [.cursor]))
        #expect(home.exists(".agents/skills/domovy/SKILL.md"))
        _ = connector.execute(connector.plan(.disconnect, command: [], agents: [.zed]))
        #expect(!home.exists(".agents/skills/domovy"))
    }

    @Test("someone else's skill named domovy is left alone")
    func foreignSkill() async throws {
        let home = try prepare()
        try home.write(".claude/skills/domovy/SKILL.md", "---\nname: domovy\ndescription: mine\n---\n")
        let connector = home.connector()
        let plan = connector.plan(.connect, command: Self.command, agents: [.claudeCode])
        #expect(plan.agents[0].notes.contains { $0.contains("different skill") })
        _ = connector.execute(plan)
        _ = connector.execute(connector.plan(.disconnect, command: [], agents: [.claudeCode]))
        #expect(home.read(".claude/skills/domovy/SKILL.md") == "---\nname: domovy\ndescription: mine\n---\n")
    }

    @Test("Claude Desktop's config is not edited while it runs")
    func desktopRunning() async throws {
        let home = try prepare()
        let connector = home.connector(running: [RunningProcess(pid: 77, name: "Claude")])
        let plan = connector.plan(.connect, command: Self.command, agents: [.claudeDesktop])
        guard case .refused(let reason) = plan.agents[0].state else {
            Issue.record("expected a refusal, got \(plan.agents[0].state)")
            return
        }
        #expect(reason.contains("Claude Desktop"))
    }

    @Test("a file changed between plan and execute is left alone")
    func changedSincePlan() async throws {
        let home = try prepare()
        let connector = home.connector()
        let plan = connector.plan(.connect, command: Self.command, agents: [.cursor])
        try home.write(".cursor/mcp.json", "{\"mcpServers\": {}}")
        let result = connector.execute(plan)
        guard case .failed = result[0].outcome else {
            Issue.record("expected a failure")
            return
        }
        #expect(home.read(".cursor/mcp.json") == "{\"mcpServers\": {}}")
    }

    @Test("a config that is not JSON is refused")
    func malformed() async throws {
        let home = try prepare()
        try home.write(".cursor/mcp.json", "not json")
        let plan = home.connector().plan(.connect, command: Self.command, agents: [.cursor])
        guard case .refused = plan.agents[0].state else {
            Issue.record("expected a refusal")
            return
        }
    }

    @Test("the embedded skill matches Resources/skill/domovy/ and the Agent Skills rules")
    func skillFile() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let file = try String(contentsOf: repo.appendingPathComponent("Resources/skill/domovy/SKILL.md"), encoding: .utf8)
        #expect(file == DomovySkill.template)
        let references = try String(contentsOf: repo.appendingPathComponent("Resources/skill/domovy/references.md"), encoding: .utf8)
        #expect(references == DomovySkill.files(command: Self.command)["references.md"])
        let lines = file.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.first == "---")
        #expect(lines.contains("name: domovy"))
        let description = try #require(lines.first { $0.hasPrefix("description: ") })
        #expect(description.count - "description: ".count <= 1_024)
    }

    @Test("the server command carries --root only for a custom home")
    func serverCommand() {
        let domo = URL(fileURLWithPath: "/opt/homebrew/bin/domo")
        #expect(MCPRegistration.serverCommand(domo: domo, home: URL(fileURLWithPath: "/Users/x"), isCustomHome: false) == ["/opt/homebrew/bin/domo", "mcp"])
        #expect(MCPRegistration.serverCommand(domo: domo, home: URL(fileURLWithPath: "/tmp/h"), isCustomHome: true) == ["/opt/homebrew/bin/domo", "mcp", "--root", "/tmp/h"])
    }
}
