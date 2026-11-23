import DomovyCore
import Foundation
import Testing

@Suite("Claude Code adapter")
struct ClaudeCodeAdapterTests {
    typealias IDs = FixtureHome.ClaudeCode

    @Test("probe recognises the fixture layout")
    func probe() async throws {
        let fixture = try FixtureHome()
        #expect(await fixture.adapter().status() == .ready)

        let missing = ClaudeCodeAdapter(configDirectory: fixture.home.appendingPathComponent("nope"))
        #expect(await missing.status() == .notInstalled)
    }

    @Test("lists every session with title, project, size and status")
    func list() async throws {
        let fixture = try FixtureHome()
        let sessions = try await fixture.adapter().sessions()
        #expect(sessions.map(\.id).sorted() == [IDs.idle, IDs.live, IDs.expiring, IDs.rosterLive].sorted())
        // Sorted by last active, newest first.
        #expect(sessions.first?.id == IDs.live)

        let idle = try #require(sessions.first { $0.id == IDs.idle })
        #expect(idle.title == "Add rate limiting to the orbit API")
        #expect(idle.projectPath == "/Users/dev/code/orbit-api")
        #expect(idle.projectName == "orbit-api")
        #expect(idle.status == .idle)
        #expect(idle.sizeBytes > 0)
        #expect(idle.agent == .claudeCode)

        // The slash-command echo is skipped; the first real prompt wins.
        let live = try #require(sessions.first { $0.id == IDs.live })
        #expect(live.title == "Refactor the billing module into smaller services")
        #expect(live.status == .live)

        // A custom-title record beats the first prompt.
        let expiring = try #require(sessions.first { $0.id == IDs.expiring })
        #expect(expiring.title == "Landing hero responsive pass")

        // Array content: first text block, first line only.
        let roster = try #require(sessions.first { $0.id == IDs.rosterLive })
        #expect(roster.title == "Set up a nightly lighthouse run")
        #expect(roster.status == .live)
    }

    @Test("artifacts cover every companion and the history.jsonl entries, never memory/")
    func artifacts() async throws {
        let fixture = try FixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        let artifacts = try await adapter.artifacts(of: session)
        let names = Set(artifacts.map { FileSystem_relative($0.url, fixture.claudeDirectory) })

        let id = IDs.idle
        let expected: Set<String> = [
            "projects/-Users-dev-code-orbit-api/\(id).jsonl",
            "projects/-Users-dev-code-orbit-api/\(id)",
            "projects/-Users-dev-code-orbit-api/\(id).orphaned-20261101-x7q2k.jsonl",
            "projects/-Users-dev-code-orbit-api/\(id).jsonl.superseded-20261101-120000",
            "file-history/\(id)",
            "uploads/\(id)",
            "dev-mods/\(id)",
            "session-env/\(id)",
            "security/security_warnings_state_\(id).json",
            "security/security_warnings_state_\(id).lock",
            "history.jsonl",
        ]
        #expect(names == expected)

        let history = try #require(artifacts.first { $0.kind == .indexEntry })
        #expect(history.note.hasPrefix("2 entries"))
        #expect(artifacts.filter { $0.kind == .indexEntry }.count == 1)
        #expect(!names.contains { $0.contains("memory") })
    }

    @Test("delete plan lists moves and history lines, excludes protected paths")
    func deletePlan() async throws {
        let fixture = try FixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: String(IDs.idle.prefix(8)))
        let plan = try await adapter.deletePlan(for: session, destination: .quarantine)

        #expect(plan.action == .delete)
        #expect(plan.destination == .quarantine)
        #expect(plan.sessionID == IDs.idle)
        #expect(!plan.liveCheck.isLive)
        #expect(plan.liveCheck.openHandles == .unavailable)
        #expect(plan.moves.count == 10)
        #expect(plan.indexEdits.count == 1)
        #expect(plan.indexEdits[0].lineNumbers == [0, 2])
        #expect(plan.totalBytes == plan.moves.reduce(0) { $0 + $1.sizeBytes } + plan.indexEdits[0].removedBytes)
        #expect(plan.summary.contains("Moves 10 items"))
        #expect(plan.summary.contains("removes 2 lines from history.jsonl"))
        #expect(plan.summary.hasSuffix("You can undo this."))

        let protected = ["memory", "plugins", "skills", "settings.json", "keybindings.json", "CLAUDE.md"]
        for move in plan.moves {
            let relative = FileSystem_relative(move.source, fixture.claudeDirectory)
            for name in protected {
                #expect(!relative.split(separator: "/").contains(Substring(name)), "\(relative) must not be planned")
            }
        }
        // Encodable: the same value travels to the UI preview and the CLI dry run.
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(Plan.self, from: data)
        #expect(decoded == plan)
    }

    @Test("live check reads sessions/*.json and daemon/roster.json")
    func liveCheck() async throws {
        let fixture = try FixtureHome()
        let adapter = fixture.adapter()

        let live = try await adapter.liveCheck(adapter.session(matching: IDs.live))
        #expect(live.isLive)
        #expect(live.reasons.count == 1)
        #expect(live.reasons[0].contains("pid 4242"))
        #expect(live.checkedSignals.contains("sessions/*.json"))

        let roster = try await adapter.liveCheck(adapter.session(matching: IDs.rosterLive))
        #expect(roster.isLive)
        #expect(roster.reasons[0].contains("background worker"))

        let idle = try await adapter.liveCheck(adapter.session(matching: IDs.idle))
        #expect(!idle.isLive)
        #expect(idle.reasons.isEmpty)
    }

    @Test("expiring follows cleanupPeriodDays from settings.json")
    func expiring() async throws {
        let now = Date()
        let fixture = try FixtureHome(now: now)
        let adapter = fixture.adapter(now: { now })
        let sessions = try await adapter.sessions()

        let expiring = try #require(sessions.first { $0.id == IDs.expiring })
        #expect(expiring.status == .expiring)
        let expiresAt = try #require(expiring.expiresAt)
        // mtime is 26 days old, period is 30: expires in 4 days.
        #expect(abs(expiresAt.timeIntervalSince(now) - 4 * 86_400) < 60)

        let idle = try #require(sessions.first { $0.id == IDs.idle })
        #expect(idle.status == .idle)
        let idleExpiresAt = try #require(idle.expiresAt)
        #expect(abs(idleExpiresAt.timeIntervalSince(now) - 28 * 86_400) < 60)

        // Without the key the documented default of 30 applies; with a shorter period more sessions expire.
        let settings = fixture.claudeDirectory.appendingPathComponent("settings.json")
        try Data("{\"cleanupPeriodDays\": 3}".utf8).write(to: settings)
        let shorter = try await fixture.adapter(now: { now }).sessions()
        #expect(shorter.first { $0.id == IDs.idle }?.status == .expiring)

        try Data("{}".utf8).write(to: settings)
        let defaulted = try await fixture.adapter(now: { now }).sessions()
        #expect(defaulted.first { $0.id == IDs.idle }?.status == .idle)
    }

    @Test("unknown transcript names make the adapter read-only")
    func unknownLayout() async throws {
        let fixture = try FixtureHome()
        let odd = fixture.claudeDirectory.appendingPathComponent("projects/-Users-dev-code-orbit-api/conversation-7.jsonl")
        try Data("{}\n".utf8).write(to: odd)

        let adapter = fixture.adapter()
        guard case .readOnly(let reason) = await adapter.status() else {
            Issue.record("expected readOnly")
            return
        }
        #expect(reason.contains("1 transcript file"))

        // Listing still works; planning is refused.
        let session = try await adapter.session(matching: IDs.idle)
        await #expect(throws: AdapterError.readOnly(.claudeCode, reason: reason)) {
            try await adapter.deletePlan(for: session, destination: .trash)
        }
    }

    @Test("archive is a typed notImplemented for now")
    func archive() async throws {
        let fixture = try FixtureHome()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        await #expect(throws: AdapterError.notImplemented(.claudeCode, feature: "archive")) {
            try await adapter.archivePlan(for: session)
        }
    }

    @Test("footprint marks plugins and skills as keep")
    func footprint() async throws {
        let fixture = try FixtureHome()
        let footprint = try await fixture.adapter().footprint()
        #expect(footprint.totalBytes > 0)
        let byName = Dictionary(uniqueKeysWithValues: footprint.categories.map { ($0.name, $0) })
        #expect(byName["Plugins"]?.disposition == .keep)
        #expect(byName["Skills"]?.disposition == .keep)
        #expect(byName["Transcripts"]?.disposition == .consequences)
    }
}

/// Path of `url` relative to `base`, for readable assertions.
func FileSystem_relative(_ url: URL, _ base: URL) -> String {
    let b = base.standardizedFileURL.path + "/"
    let p = url.standardizedFileURL.path
    return p.hasPrefix(b) ? String(p.dropFirst(b.count)) : p
}
