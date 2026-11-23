import DomovyCore
import Foundation

/// A throwaway home with `.gemini` copied from `Tests/Fixtures/gemini/<version>/`, real project
/// folders under `<base>/code` (Gemini CLI runs from them), and the stub CLI at `<base>/bin/gemini`.
final class GeminiFixtureHome: Sendable {
    enum IDs {
        static let idle = "e1e1e1e1-1111-4111-8111-111111111111"
        static let digit = "7d7d7d7d-2222-4222-8222-222222222222"
        static let old = "e3e3e3e3-3333-4333-8333-333333333333"
        /// Gemini CLI's a2a server reuses one id; Domovy appends the chat's time.
        static let a2aFirst = "a2a-server-2026-11-18t07-44"
    }

    static let idleChat = "tmp/orbit-api/chats/session-2026-11-20T09-15-e1e1e1e1.jsonl"
    static let digitChat = "tmp/orbit-api/chats/session-2026-11-21T10-00-7d7d7d7d.jsonl"
    static let oldChat = "tmp/orbit-api/chats/session-2026-10-28T14-30-e3e3e3e3.jsonl"
    static let a2aChats = ["tmp/landing-site/chats/session-2026-11-18T07-44-a2a-serv.jsonl",
                           "tmp/landing-site/chats/session-2026-11-18T07-45-a2a-serv.jsonl"]

    let home: URL
    let storeRoot: URL
    let stub: URL
    /// `<base>/code/orbit-api`, the project the orbit-api chats belong to.
    let project: URL
    var geminiDirectory: URL { home.appendingPathComponent(".gemini", isDirectory: true) }

    init(version: String = "0.43", now: Date = Date()) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-gemini-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        stub = base.appendingPathComponent("bin/gemini")
        project = base.appendingPathComponent("code/orbit-api", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let fixtures = FixtureHome.fixturesRoot.appendingPathComponent("gemini", isDirectory: true)
        try fm.copyItem(at: fixtures.appendingPathComponent(version, isDirectory: true), to: geminiDirectory)
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("code/landing-site"), withIntermediateDirectories: true)
        // Point the fixture's project paths at the real folders.
        let code = base.appendingPathComponent("code").path
        for file in ["projects.json", "tmp/orbit-api/.project_root", "tmp/landing-site/.project_root"] {
            let text = try String(contentsOf: url(file), encoding: .utf8).replacingOccurrences(of: "/Users/dev/code", with: code)
            try text.write(to: url(file), atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: stub.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("stub-gemini.sh"), to: stub)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let day: TimeInterval = 86_400
        try setDate(Self.idleChat, now.addingTimeInterval(-2 * day))
        try setDate(Self.digitChat, now.addingTimeInterval(-1 * day))
        try setDate(Self.oldChat, now.addingTimeInterval(-26 * day))
        for chat in Self.a2aChats { try setDate(chat, now.addingTimeInterval(-5 * day)) }
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Deterministic: no libproc, no running Gemini CLI, the stub CLI unless told otherwise.
    func adapter(
        cli: ToolChoice? = nil,
        openHandles: any OpenHandleChecker = UnavailableOpenHandleChecker(),
        running: [RunningProcess]? = [],
        arguments: [Int32: [String]] = [:],
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> GeminiAdapter {
        GeminiAdapter(geminiHome: geminiDirectory, cli: cli ?? .executable(stub), openHandles: openHandles,
                      processes: FixedProcessLister(running, arguments: arguments), now: now)
    }

    func executor(running: [RunningProcess]? = []) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running))
    }

    func url(_ relative: String) -> URL { geminiDirectory.appendingPathComponent(relative) }
    func exists(_ relative: String) -> Bool { FileManager.default.fileExists(atPath: url(relative).path) }
    func touch(_ marker: String) { FileManager.default.createFile(atPath: url(marker).path, contents: Data()) }

    func write(_ relative: String, _ text: String) throws {
        try text.write(to: url(relative), atomically: true, encoding: .utf8)
    }

    func modificationDate(_ relative: String) -> Date? {
        (try? url(relative).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    func setDate(_ relative: String, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url(relative).path)
    }

    func stubInvocations() -> [String] {
        ((try? String(contentsOf: url(".stub-gemini.log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

/// A throwaway home with Antigravity's two stores from `Tests/Fixtures/antigravity/<version>/`,
/// conversation databases built from `Tests/Fixtures/antigravity/sql/`.
final class AntigravityFixtureHome: Sendable {
    enum IDs {
        /// CLI store; title from the metadata cache.
        static let uploader = "a1a1a1a1-1111-4111-8111-111111111111"
        /// CLI store; title from conversation_summaries.db.
        static let landing = "b2b2b2b2-2222-4222-8222-222222222222"
        /// App store; open (presence lock).
        static let open = "c3c3c3c3-3333-4333-8333-333333333333"
    }

    let home: URL
    let storeRoot: URL
    var geminiDirectory: URL { home.appendingPathComponent(".gemini", isDirectory: true) }
    var cliStore: URL { geminiDirectory.appendingPathComponent("antigravity-cli", isDirectory: true) }
    var appStore: URL { geminiDirectory.appendingPathComponent("antigravity", isDirectory: true) }

    init(version: String = "1.5", now: Date = Date()) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-antigravity-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        let fixtures = FixtureHome.fixturesRoot.appendingPathComponent("antigravity", isDirectory: true)
        try fm.copyItem(at: fixtures.appendingPathComponent(version, isDirectory: true), to: geminiDirectory)
        let conversation = try String(contentsOf: fixtures.appendingPathComponent("sql/conversation.sql"), encoding: .utf8)
        let summaries = try String(contentsOf: fixtures.appendingPathComponent("sql/summaries.sql"), encoding: .utf8)
        for (store, id) in [(cliStore, IDs.uploader), (cliStore, IDs.landing), (appStore, IDs.open)] {
            let folder = store.appendingPathComponent("conversations", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try CodexFixtureHome.buildDatabase(conversation, at: folder.appendingPathComponent("\(id).db"))
        }
        try CodexFixtureHome.buildDatabase(summaries, at: cliStore.appendingPathComponent("conversation_summaries.db"))
        let day: TimeInterval = 86_400
        try setDate(cliStore.appendingPathComponent("conversations/\(IDs.uploader).db"), now.addingTimeInterval(-1 * day))
        try setDate(cliStore.appendingPathComponent("conversations/\(IDs.landing).db"), now.addingTimeInterval(-3 * day))
        try setDate(appStore.appendingPathComponent("conversations/\(IDs.open).db"), now.addingTimeInterval(-600))
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    func adapter(openHandles: any OpenHandleChecker = UnavailableOpenHandleChecker()) -> AntigravityAdapter {
        AntigravityAdapter(geminiHome: geminiDirectory, openHandles: openHandles, processes: FixedProcessLister([]))
    }

    func setDate(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}
