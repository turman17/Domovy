@testable import DomovyCore
import Foundation
import Testing

/// Goose, Amazon Q CLI and Kiro list read-only; Windsurf, Trae, Warp, Amp, Junie and iFlow are only
/// measured. Each builds a throwaway home from Tests/Fixtures (see the READMEs there).
@Suite("Read-only and measured agents")
struct ReadOnlyAgentTests {
    final class Home: Sendable {
        let home: URL

        init() throws {
            home = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-readonly-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }

        func write(_ relative: String, _ text: String) throws {
            try FileManager.default.createDirectory(at: url(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url(relative))
        }

        func database(_ relative: String, fixture: String) throws {
            try FileManager.default.createDirectory(at: url(relative).deletingLastPathComponent(), withIntermediateDirectories: true)
            try CodexFixtureHome.buildDatabase(String(contentsOf: FixtureHome.fixturesRoot.appendingPathComponent(fixture), encoding: .utf8), at: url(relative))
        }

        func snapshot() -> [String: Data] {
            var result: [String: Data] = [:]
            let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)
            while let item = enumerator?.nextObject() as? URL { result[item.path] = (try? Data(contentsOf: item)) ?? Data() }
            return result
        }
    }

    static let quiet = FixedOpenHandleChecker(holders: [])

    @Test("Goose lists sessions from either data folder and refuses every plan")
    func goose() async throws {
        let home = try Home()
        try home.database(".local/share/goose/sessions/sessions.db", fixture: "goose/sql/sessions.sql")
        try home.write(".config/goose/secrets.yaml", "synthetic: true\n")
        let adapter = GooseAdapter(home: home.home, openHandles: Self.quiet)
        guard case .readOnly(let reason) = await adapter.status() else { Issue.record("not read-only"); return }
        #expect(reason == GooseAdapter.readOnlyReason)
        let sessions = try await adapter.sessions()
        #expect(sessions.map(\.id) == ["20261120_1", "20261101_2"])
        #expect(sessions[0].title == "Uploader retries" && sessions[0].projectPath == "/Users/dev/code/orbit-api")
        #expect(sessions[1].status == .archived)
        #expect(try await adapter.transcript(of: sessions[0], limit: 10).messages.map(\.role) == [.user, .assistant])
        let before = home.snapshot()
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: sessions[0]) }
        await #expect(throws: AdapterError.self) { try await adapter.archivePlan(for: sessions[0]) }
        #expect(home.snapshot() == before)
        let footprint = try await adapter.footprint()
        #expect(footprint.categories.contains { $0.name == "Settings and secrets" && $0.disposition == .keep })

        // The Application Support location works the same.
        let other = try Home()
        try other.database("Library/Application Support/Block/goose/sessions/sessions.db", fixture: "goose/sql/sessions.sql")
        #expect(try await GooseAdapter(home: other.home, openHandles: Self.quiet).sessions().count == 2)
        // An unknown schema is still read-only, with the reason, and lists nothing.
        let odd = try Home()
        try FileManager.default.createDirectory(at: odd.url(".local/share/goose/sessions"), withIntermediateDirectories: true)
        try CodexFixtureHome.buildDatabase("CREATE TABLE sessions (id TEXT);", at: odd.url(".local/share/goose/sessions/sessions.db"))
        guard case .readOnly(let oddReason) = await GooseAdapter(home: odd.home, openHandles: Self.quiet).status() else { Issue.record("not read-only"); return }
        #expect(oddReason.contains("does not know"))
        #expect(try await GooseAdapter(home: odd.home, openHandles: Self.quiet).sessions().isEmpty)
    }

    @Test("Amazon Q lists one conversation per folder and never plans a change to its sign-in database")
    func amazonQ() async throws {
        let home = try Home()
        try home.database("Library/Application Support/amazon-q/data.sqlite3", fixture: "amazon-q/sql/data.sql")
        let adapter = AmazonQAdapter(supportDirectory: home.url("Library/Application Support/amazon-q"), openHandles: Self.quiet)
        guard case .readOnly(let reason) = await adapter.status() else { Issue.record("not read-only"); return }
        #expect(reason.contains("sign-in"))
        let sessions = try await adapter.sessions()
        #expect(sessions.map(\.id) == ["q1q1q1q1-1111-4111-8111-111111111111"])
        #expect(sessions[0].projectPath == "/Users/dev/code/orbit-api")
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: sessions[0]) }
        #expect(try await adapter.footprint().categories.allSatisfy { $0.disposition == .keep })
    }

    @Test("Kiro lists CLI 3.0 and 2.x sessions read-only and measures the IDE")
    func kiro() async throws {
        let home = try Home()
        try FileManager.default.copyItem(at: FixtureHome.fixturesRoot.appendingPathComponent("kiro/3.0/.kiro", isDirectory: true), to: home.url(".kiro"))
        try home.write("Library/Application Support/Kiro/User/globalStorage/kiro.kiroagent/abc/chat.json", "{}")
        let adapter = KiroAdapter(home: home.home, openHandles: Self.quiet)
        guard case .readOnly(let reason) = await adapter.status() else { Issue.record("not read-only"); return }
        #expect(reason == KiroAdapter.readOnlyReason)
        let sessions = try await adapter.sessions()
        #expect(Set(sessions.map(\.id)) == ["k1k1k1k1-1111-4111-8111-111111111111", "k2k2k2k2-2222-4222-8222-222222222222"])
        #expect(sessions.first { $0.id.hasPrefix("k1") }?.title == "Set up the deploy pipeline")
        #expect(sessions.first { $0.id.hasPrefix("k2") }?.projectPath == "/Users/dev/code/landing-site")
        await #expect(throws: AdapterError.self) { try await adapter.deletePlan(for: sessions[0]) }
        await #expect(throws: AdapterError.self) { try await adapter.archivePlan(for: sessions[0]) }
        #expect(try await adapter.footprint().categories.contains { $0.name == "IDE chats" })
        #expect(await KiroAdapter(home: try Home().home).status() == .notInstalled)
    }

    @Test("measured-only agents report their folders without double counting and are not session agents")
    func measured() async throws {
        let home = try Home()
        try home.write(".codeium/windsurf/cascade/abc.pb", String(repeating: "x", count: 5000))
        try home.write(".codeium/windsurf/memories/global_rules.md", "be kind\n")
        try home.write(".codeium/windsurf/user_settings.pb", "s")
        try home.write(".iflow/settings.json", "{}")
        try home.write(".iflow/tmp/abc/chat.json", "{}")
        let windsurf = try await MeasuredAgentFootprint(kind: .windsurf, home: home.home).footprint()
        #expect(windsurf.categories.map(\.name) == ["Cascade conversations", "Memories and rules", "Other"])
        #expect(windsurf.categories.first { $0.name == "Other" }?.items.map(\.lastPathComponent) == ["user_settings.pb"])
        #expect(windsurf.categories.allSatisfy { $0.guidance == nil })
        let iflow = try await MeasuredAgentFootprint(kind: .iflow, home: home.home).footprint()
        #expect(iflow.categories.map(\.name) == ["Chats and checkpoints", "Settings"])
        await #expect(throws: AdapterError.self) { try await MeasuredAgentFootprint(kind: .warp, home: home.home).footprint() }
        #expect(Set(MeasuredAgentFootprint.all(home: home.home).map(\.kind)) == [.windsurf, .trae, .warp, .amp, .junie, .iflow])
        #expect(AgentKind.allCases.filter(\.isFootprintOnly).allSatisfy { !$0.hasSessions })
    }

    @Test("agents not verified on a real install are marked experimental")
    func experimental() {
        for kind in [AgentKind.claudeCode, .claudeDesktop, .codex, .cursor, .gemini, .antigravity, .openCode, .zed, .vsCodeChat, .geminiCodeAssist, .herdr] {
            #expect(!kind.isExperimental, "\(kind)")
        }
        for kind in [AgentKind.copilot, .qwen, .kimi, .goose, .amazonQ, .windsurf, .lmStudio] {
            #expect(kind.isExperimental, "\(kind)")
        }
    }

    @Test("every new agent is registered once in the standard adapters")
    func registry() {
        let kinds = DomovyContext.standardAdapters(home: URL(fileURLWithPath: "/nonexistent-domovy-home"), isCustomHome: true).map(\.kind)
        for kind in [AgentKind.auggie, .factoryDroid, .aider, .kiro, .goose, .grok, .amazonQ] {
            #expect(kinds.filter { $0 == kind }.count == 1, "\(kind)")
        }
        #expect(SessionAgent.id(of: .factoryDroid) == "factory-droid" && SessionAgent.id(of: .amazonQ) == "amazon-q")
    }
}
