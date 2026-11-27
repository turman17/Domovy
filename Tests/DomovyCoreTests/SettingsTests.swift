@testable import DomovyCore
import Foundation
import Testing

@Suite("Settings")
struct SettingsTests {
    typealias IDs = FixtureHome.ClaudeCode

    /// An empty Domovy folder under a temp directory.
    private final class Store: Sendable {
        let root: URL
        var store: SettingsStore { SettingsStore(storeRoot: root) }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-settings-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ text: String) throws {
            try Data(text.utf8).write(to: store.file)
        }

        func object() throws -> [String: JSONValue] {
            try #require(try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.file)).objectValue)
        }
    }

    @Test("no file means defaults, and saving defaults writes an empty object")
    func defaults() throws {
        let home = try Store()
        let loaded = home.store.load()
        #expect(loaded.settings == DomovySettings())
        #expect(loaded.issues.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.store.file.path), "loading never creates the file")
        let settings = DomovySettings()
        #expect(settings.menuBarDisplay == .iconOnly)
        #expect(settings.deleteDestination == .trash)
        #expect(settings.showsInDock && settings.transcriptIndex)
        #expect(settings.expiringWindowDays == 7 && settings.nightlyHour == 3)
        try home.store.save(settings)
        #expect(try home.object().isEmpty)
    }

    @Test("changed values round trip under dotted keys, in an owner-only file")
    func roundTrip() throws {
        let home = try Store()
        var settings = DomovySettings()
        settings.menuBarDisplay = .reclaimableSize
        settings.showsInDock = false
        settings.defaultSort = .size
        settings.hiddenColumns = ["tokens", "cost"]
        settings.sessionsLayout = .projects
        settings.expiringWindowDays = 14
        settings.deleteDestination = .quarantine
        settings.hiddenAgents = [.cursor, .ollama]
        settings.aiderSearchFolders = ["~/code", "/Volumes/Work"]
        settings.transcriptIndex = false
        settings.nightlyHour = 22
        try home.store.save(settings)

        let loaded = home.store.load()
        #expect(loaded.settings == settings)
        #expect(loaded.issues.isEmpty)
        let object = try home.object()
        #expect(object["safety.deleteDestination"] == "quarantine")
        #expect(object["agents.hidden"] == ["cursor", "ollama"])
        #expect(object["menuBar.popover.rules"] == nil, "defaults are not written")
        #expect(FileSystem.posixPermissions(of: home.store.file) == 0o600)

        var reset = loaded.settings
        reset.reset(.deleteDestination)
        #expect(reset.deleteDestination == .trash)
        #expect(reset.isDefault(.deleteDestination) && !reset.isDefault(.nightlyHour))
    }

    @Test("keys Domovy does not know are kept when it saves")
    func unknownKeysKept() throws {
        let home = try Store()
        try home.write(#"{"future.setting": {"nested": [1, 2]}, "rules.nightlyHour": 5}"#)
        var settings = home.store.load().settings
        #expect(settings.nightlyHour == 5)
        settings.nightlyHour = 6
        try home.store.save(settings)
        let object = try home.object()
        #expect(object["future.setting"] == ["nested": [1, 2]])
        #expect(object["rules.nightlyHour"] == 6)
    }

    @Test("values of the wrong type or out of range fall back to defaults, with a note")
    func invalidValues() throws {
        let home = try Store()
        try home.write("""
        {
          "menuBar.display": "sparkles",
          "sessions.expiringWarningDays": 90,
          "rules.nightlyHour": "three",
          "app.showInDock": false,
          "agents.hidden": ["codex", "notAnAgent"],
          "agents.aider.searchFolders": "/not/a/list"
        }
        """)
        let loaded = home.store.load()
        #expect(loaded.settings.menuBarDisplay == .iconOnly)
        #expect(loaded.settings.expiringWindowDays == 7)
        #expect(loaded.settings.nightlyHour == 3)
        #expect(loaded.settings.showsInDock == false, "good values next to bad ones still apply")
        #expect(loaded.settings.hiddenAgents == [.codex])
        #expect(loaded.settings.aiderSearchFolders.isEmpty)
        #expect(Set(loaded.issues.map(\.key)) == ["menuBar.display", "sessions.expiringWarningDays", "rules.nightlyHour", "agents.hidden", "agents.aider.searchFolders"])
    }

    @Test("a file that is not JSON gives defaults and is backed up before it is replaced")
    func unreadableFile() throws {
        let home = try Store()
        try home.write("{ not json")
        let loaded = home.store.load()
        #expect(loaded.isUnreadable)
        #expect(loaded.settings == DomovySettings())
        #expect(loaded.issues.count == 1)
        try home.store.save(loaded.settings)
        let backup = home.root.appendingPathComponent("settings.json.bak")
        #expect(try String(contentsOf: backup, encoding: .utf8) == "{ not json")
        #expect(!home.store.load().isUnreadable)
    }

    @Test("aider-search-roots.txt moves into settings.json once")
    func aiderMigration() throws {
        let home = try Store()
        let legacy = home.root.appendingPathComponent("aider-search-roots.txt")
        try Data("~/projects\n\n  /Volumes/Work  \n".utf8).write(to: legacy)
        let loaded = home.store.load()
        #expect(loaded.settings.aiderSearchFolders == ["~/projects", "/Volumes/Work"])
        #expect(try home.object()["agents.aider.searchFolders"] == ["~/projects", "/Volumes/Work"])
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathExtension("migrated").path))

        // A list written later by an old version is not read over the settings.
        try Data("/elsewhere\n".utf8).write(to: legacy)
        #expect(home.store.load().settings.aiderSearchFolders == ["~/projects", "/Volumes/Work"])

        let urls = loaded.settings.aiderSearchURLs(home: URL(fileURLWithPath: "/Users/dev"))
        #expect(urls.map(\.path) == ["/Users/dev/projects", "/Volumes/Work"])
    }

    @Test("hidden agents are left out of the standard adapters, the scan and the footprints")
    func hiddenAgents() async throws {
        let fixture = try FixtureHome()
        let storeRoot = DomovyContext.storeRoot(home: fixture.home)
        let shown = DomovyContext(home: fixture.home, isCustomHome: true)
        #expect(shown.adapters.contains { $0.kind == .claudeCode })
        #expect(await shown.scanSessions().contains { $0.adapter.kind == .claudeCode })

        var settings = DomovySettings()
        settings.hiddenAgents = [.claudeCode, .claudeDesktop, .aider, .ollama]
        try SettingsStore(storeRoot: storeRoot).save(settings)
        // Read from settings.json, as domo and the MCP server do.
        let context = DomovyContext(home: fixture.home, isCustomHome: true)
        #expect(context.settings.hiddenAgents == settings.hiddenAgents)
        let kinds = Set(context.adapters.map(\.kind))
        #expect(!kinds.contains(.claudeCode) && !kinds.contains(.aider))
        #expect(kinds.contains(.codex))
        let scanned = await context.scanSessions()
        #expect(!scanned.contains { $0.adapter.kind == .claudeCode })
        #expect(try await context.allSessions().isEmpty)
        let measured = Set(context.footprintProviders.map(\.kind))
        #expect(measured.isDisjoint(with: settings.hiddenAgents))
        #expect(measured.contains(.lmStudio))
    }

    @Test("the expiring window comes from settings")
    func expiringWindow() async throws {
        let fixture = try FixtureHome()
        var settings = DomovySettings()
        let wide = DomovyContext(home: fixture.home, isCustomHome: true, settings: settings)
        let expiring = try await wide.allSessions().first { $0.session.id == IDs.expiring }
        #expect(expiring?.session.status == .expiring)

        settings.expiringWindowDays = 1
        let narrow = DomovyContext(home: fixture.home, isCustomHome: true, settings: settings)
        let notYet = try await narrow.allSessions().first { $0.session.id == IDs.expiring }
        #expect(notYet?.session.status == .idle)
    }

    @Test("the default destination is used without --to or an MCP destination")
    func defaultDestination() async throws {
        var settings = DomovySettings()
        #expect(settings.destination(nil) == .trash)
        settings.deleteDestination = .quarantine
        #expect(settings.destination(nil) == .quarantine)
        #expect(settings.destination(.trash) == .trash, "an explicit --to wins")

        let fixture = try FixtureHome()
        let context = DomovyContext(home: fixture.home, isCustomHome: true, adapters: [fixture.adapter()], executor: fixture.executor(), settings: settings)
        let plan = await DomovyTools(context: context).call("plan_delete", arguments: ["session_ids": [.string(IDs.idle)]])
        #expect(!plan.isError, "\(plan.text)")
        #expect(plan.structured["destination"] == "quarantine")
    }
}
