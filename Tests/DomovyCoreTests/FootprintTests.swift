import DomovyCore
import Foundation
import Testing

@Suite("Footprints")
struct FootprintTests {
    private static let day: TimeInterval = 86_400
    private static let orphanID = "eeeeeeee-5555-4555-8555-555555555555"
    private static let freshID = "ffffffff-6666-4666-8666-666666666666"

    // MARK: Claude Code

    @Test("Claude Code: categories, dispositions, and nothing counted twice or missed")
    func claudeCode() async throws {
        let fixture = try FixtureHome()
        let footprint = try await fixture.adapter().footprint()
        let byName = Self.byName(footprint)

        #expect(byName["Session transcripts"]?.disposition == .consequences)
        #expect(byName["Session transcripts"]?.guidance == .manageInSessions)
        #expect(byName["Session transcripts"]?.note.hasPrefix("4 sessions.") == true)
        #expect(byName["Checkpoints"]?.disposition == .consequences)
        #expect(byName["Session environments"]?.disposition == .safe)
        #expect(byName["Orphaned companions"] == nil, "every companion in the fixture has its transcript")

        let keep = try #require(byName["Settings, plugins, skills, memory"])
        #expect(keep.disposition == .keep)
        let kept = Set(keep.items.map { FileSystem_relative($0, fixture.claudeDirectory) })
        #expect(kept.isSuperset(of: ["plugins", "skills", "settings.json", "keybindings.json", "CLAUDE.md", "projects/-Users-dev-code-orbit-api/memory"]))

        #expect(footprint.totalBytes == Self.allocatedBytes(below: fixture.claudeDirectory))
    }

    @Test("Claude Code: the agent SDK venv is safe to remove; the rest of security/ is not")
    func agentSDKVenv() async throws {
        let fixture = try FixtureHome()
        try Self.write("security/agent-sdk-venv/lib/site.py", in: fixture.claudeDirectory)
        let byName = Self.byName(try await fixture.adapter().footprint())
        #expect(byName["Agent SDK environment"]?.disposition == .safe)
        #expect(byName["Security state"]?.disposition == .consequences)
        #expect(byName["Security state"]?.items.contains { $0.lastPathComponent == "agent-sdk-venv" } == false)
    }

    @Test("Claude Code: companions whose transcript is gone are orphans; fresh ones are not")
    func orphans() async throws {
        let fixture = try FixtureHome()
        let root = fixture.claudeDirectory
        let old = Date().addingTimeInterval(-3 * Self.day)
        for path in ["file-history/\(Self.orphanID)", "projects/-Users-dev-code-orbit-api/\(Self.orphanID)", "session-env/\(Self.orphanID)"] {
            try Self.write("\(path)/data.json", in: root)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: root.appendingPathComponent(path).path)
        }
        try Self.write("file-history/\(Self.freshID)/data.json", in: root)

        let footprint = try await fixture.adapter().footprint()
        let orphans = try #require(Self.byName(footprint)["Orphaned companions"])
        #expect(orphans.disposition == .safe)
        #expect(Set(orphans.items.map { FileSystem_relative($0, root) }) == [
            "file-history/\(Self.orphanID)", "projects/-Users-dev-code-orbit-api/\(Self.orphanID)", "session-env/\(Self.orphanID)",
        ])
        #expect(orphans.note == "3 folders whose transcript is already gone.")
        #expect(footprint.totalBytes == Self.allocatedBytes(below: root))
    }

    @Test("no removable category ever covers what an agent needs to run")
    func protectedPathsAreKeep() async throws {
        let claude = try FixtureHome()
        let codex = try CodexFixtureHome()
        let claudeProtected = ["plugins", "settings.json", "skills", "keybindings.json", "CLAUDE.md", "daemon"]
        let codexProtected = ["auth.json", "config.toml", "rules", "skills", "plugins", "AGENTS.md"]
        for (footprint, root, protected) in [
            (try await claude.adapter().footprint(), claude.claudeDirectory, claudeProtected),
            (try await codex.adapter().footprint(), codex.codexDirectory, codexProtected),
        ] {
            for category in footprint.categories where category.disposition != .keep {
                for item in category.revealURLs + [category.url] {
                    let relative = FileSystem_relative(item, root)
                    #expect(!protected.contains(String(relative.split(separator: "/").first ?? "")), "\(category.name) covers \(relative)")
                    #expect(!relative.hasSuffix("/memory"), "\(category.name) covers \(relative)")
                }
            }
        }
    }

    // MARK: Codex

    @Test("Codex: rollouts, large rollouts, logs and databases")
    func codex() async throws {
        let fixture = try CodexFixtureHome()
        let root = fixture.codexDirectory
        for name in ["logs_2.sqlite", "logs_2.sqlite-wal"] { try Self.write(name, in: root) }
        try Self.write("worktrees/1f2e/orbit-api/README.md", in: root)
        let large = "sessions/2026/11/21/rollout-2026-11-21T10-00-00-01a1f066-6666-7666-8666-666666666666.jsonl"
        try Self.sparseFile(large, in: root, bytes: 101_000_000)

        let footprint = try await fixture.adapter().footprint()
        let byName = Self.byName(footprint)
        let largeRow = try #require(byName["Large rollouts"])
        #expect(largeRow.items.map { FileSystem_relative($0, root) } == [large])
        #expect(largeRow.logicalBytes >= 101_000_000)
        #expect(largeRow.guidance == .cleanup(.codexLargeRollouts))
        let rollouts = try #require(byName["Session rollouts"])
        #expect(!rollouts.items.contains { FileSystem_relative($0, root) == large })
        #expect(rollouts.disposition == .consequences)
        #expect(byName["Logs database"]?.disposition == .safe)
        #expect(byName["Logs database"]?.items.count == 2)
        #expect(byName["Thread databases"]?.disposition == .keep)
        #expect(byName["Thread databases"]?.items.map(\.lastPathComponent).contains("state_5.sqlite") == true)
        #expect(byName["Worktrees"]?.disposition == .consequences)
        #expect(byName["Generated images"]?.disposition == .consequences)
        #expect(byName["Settings, auth, rules, skills, plugins"]?.disposition == .keep)
        #expect(footprint.totalBytes == Self.allocatedBytes(below: root))
    }

    // MARK: Claude Desktop

    @Test("Claude Desktop: VM bundle, caches, registry; the sparse VM counts what it uses")
    func claudeDesktop() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true)
        try Self.copyFixture("claude-desktop/1.0", to: support)
        try Self.sparseFile("vm_bundles/claudevm.bundle/rootfs.img", in: support, bytes: 2_000_000_000)

        let footprint = try await ClaudeDesktopFootprint(home: home).footprint()
        let byName = Self.byName(footprint)
        let vm = try #require(byName["VM bundle"])
        #expect(vm.disposition == .consequences)
        #expect(vm.note == "Removing it frees space; Cowork state is lost and the VM may download again.")
        #expect(vm.logicalBytes > 2_000_000_000)
        #expect(vm.sizeBytes < 10_000_000, "a sparse image counts its allocated blocks")
        #expect(byName["Electron caches"]?.disposition == .safe)
        #expect(Set(byName["Electron caches"]?.items.map(\.lastPathComponent) ?? []) == ["Cache", "Code Cache", "GraphiteDawnCache"])
        #expect(byName["Session registry"]?.disposition == .keep)
        #expect(byName["Cowork sessions"]?.disposition == .consequences)
        #expect(byName["Other"]?.disposition == .keep)
        #expect(footprint.totalBytes == Self.allocatedBytes(below: support))
    }

    // MARK: Cursor

    @Test("Cursor: the chats database is guided, never touched; everything else is keep")
    func cursor() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        let support = home.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
        let dot = home.appendingPathComponent(".cursor", isDirectory: true)
        try Self.copyFixture("cursor/3.0/support", to: support)
        try Self.copyFixture("cursor/3.0/dot-cursor", to: dot)
        let database = support.appendingPathComponent("User/globalStorage/state.vscdb")
        let before = try Data(contentsOf: database)
        let modified = try database.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let footprint = try await CursorFootprint(home: home).footprint()
        let byName = Self.byName(footprint)
        let chats = try #require(byName["Chats database"])
        #expect(chats.disposition == .consequences)
        #expect(chats.guidance == .instructions(CursorFootprint.chatCleanupSteps))
        #expect(Set(chats.items.map(\.lastPathComponent)) == ["state.vscdb", "state.vscdb.backup"])
        #expect(byName["CLI chats"]?.disposition == .consequences)
        for category in footprint.categories where category.name != "Chats database" && category.name != "CLI chats" {
            #expect(category.disposition == .keep, "\(category.name)")
        }
        #expect(footprint.totalBytes == Self.allocatedBytes(below: support) + Self.allocatedBytes(below: dot))
        #expect(try Data(contentsOf: database) == before)
        #expect(try database.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == modified)
    }

    @Test("Cursor with only ~/.cursor still reports it")
    func cursorCLIOnly() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        try Self.copyFixture("cursor/3.0/dot-cursor", to: home.appendingPathComponent(".cursor", isDirectory: true))
        let footprint = try await CursorFootprint(home: home).footprint()
        #expect(Self.byName(footprint)["CLI chats"] != nil)
        #expect(Self.byName(footprint)["Chats database"] == nil)
    }

    // MARK: Missing agents

    @Test("missing agents are not installed and the scanner leaves them out")
    func missingAgents() async throws {
        let home = try Self.home()
        defer { try? FileManager.default.removeItem(at: home) }
        await #expect(throws: AdapterError.notInstalled(.claudeDesktop)) { try await ClaudeDesktopFootprint(home: home).footprint() }
        await #expect(throws: AdapterError.notInstalled(.cursor)) { try await CursorFootprint(home: home).footprint() }
        await #expect(throws: AdapterError.notInstalled(.claudeCode)) { try await ClaudeCodeAdapter(home: home).footprint() }

        try Self.copyFixture("claude-desktop/1.0", to: home.appendingPathComponent("Library/Application Support/Claude", isDirectory: true))
        let providers: [any FootprintProvider] = [ClaudeCodeAdapter(home: home), CodexAdapter(home: home)] + FootprintScanner.measuredOnly(home: home)
        let result = await FootprintScanner.scan(providers)
        #expect(result.footprints.map(\.agent) == [.claudeDesktop])
        #expect(result.failures.isEmpty)
    }

    // MARK: Helpers

    private static func byName(_ footprint: Footprint) -> [String: Footprint.Category] {
        Dictionary(uniqueKeysWithValues: footprint.categories.map { ($0.name, $0) })
    }

    private static func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-footprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func copyFixture(_ relative: String, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: FixtureHome.fixturesRoot.appendingPathComponent(relative, isDirectory: true), to: destination)
    }

    private static func write(_ relative: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("synthetic\n".utf8).write(to: url)
    }

    /// A file of `bytes` logical length that allocates almost nothing (APFS sparse file).
    private static func sparseFile(_ relative: String, in root: URL, bytes: UInt64) throws {
        try write(relative, in: root)
        let handle = try FileHandle(forWritingTo: root.appendingPathComponent(relative))
        try handle.truncate(atOffset: bytes)
        try handle.close()
    }

    /// Independent total: every regular file's allocated size below `root`.
    private static func allocatedBytes(below root: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
