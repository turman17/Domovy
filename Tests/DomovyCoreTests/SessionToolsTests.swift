@testable import DomovyCore
import Foundation
import Testing

@Suite("Projects, export, resume, scans")
struct SessionToolsTests {
    // MARK: Projects

    @Test("Projects group sessions of every agent by folder, with totals")
    func projectGroups() throws {
        let now = Date()
        let sessions = [
            makeSession("a", agent: .claudeCode, project: "/Users/dev/code/orbit-api", lastActive: now.addingTimeInterval(-100), size: 100),
            makeSession("b", agent: .codex, project: "/Users/dev/code/orbit-api/", lastActive: now.addingTimeInterval(-10), size: 50),
            makeSession("c", agent: .gemini, project: "/Users/dev/code/landing", lastActive: now.addingTimeInterval(-1000), size: 7),
            makeSession("d", agent: .cursor, project: nil, lastActive: now, size: 1),
        ]
        let groups = ProjectGroup.group(sessions)
        #expect(groups.map(\.name) == ["orbit-api", "landing", "No project"])
        let orbit = groups[0]
        #expect(orbit.sessions.map(\.id) == ["b", "a"])
        #expect(orbit.sizeBytes == 150)
        #expect(orbit.lastActive == now.addingTimeInterval(-10))
        #expect(Set(orbit.agents) == [.claudeCode, .codex])

        var usage = TokenUsage()
        usage.add(TokenCounts(input: 10, output: 5), model: "claude-haiku-4-5")
        var other = TokenUsage()
        other.add(TokenCounts(input: 1, cacheRead: 2), model: "gpt-5")
        let tokens = orbit.tokens(in: ["a": .usage(usage), "b": .usage(other), "c": .usage(usage)])
        #expect(tokens.counted == 2)
        #expect(tokens.usage.totals == TokenCounts(input: 11, output: 5, cacheRead: 2))
        #expect(groups[2].tokens(in: [:]).counted == 0)
    }

    // MARK: Export

    @Test("Export masks secrets by default and keeps them only when asked")
    func exportMasks() throws {
        let session = makeSession("e1", agent: .codex)
        let transcript = Transcript(messages: [
            TranscriptMessage(id: "1", role: .user, timestamp: nil, blocks: [.text("deploy with \(SecretSamples.github) please")]),
            TranscriptMessage(id: "2", role: .assistant, timestamp: nil, blocks: [.text("Done."), .toolCall("shell git push")]),
        ], isTruncated: true)
        let item = TranscriptExport.Item(session: session, transcript: transcript)
        let masked = TranscriptExport.markdown([item], masksSecrets: true)
        #expect(!masked.markdown.contains(SecretSamples.github))
        #expect(masked.maskedCount == 1)
        #expect(masked.markdown.contains("# Session e1"))
        #expect(masked.markdown.contains("## You"))
        #expect(masked.markdown.contains("> Tool: shell git push"))
        #expect(masked.markdown.contains("longer than Domovy reads"))
        let raw = TranscriptExport.markdown([item], masksSecrets: false)
        #expect(raw.markdown.contains(SecretSamples.github))
        #expect(raw.maskedCount == 0)

        let two = TranscriptExport.markdown([item, item], masksSecrets: true)
        #expect(two.markdown.hasPrefix("# 2 agent sessions"))
        #expect(two.maskedCount == 2)
    }

    @Test("Export reads through the adapters, zstd rollouts included")
    func exportReadsCodex() async throws {
        let fixture = try CodexFixtureHome()
        let adapter = fixture.adapter()
        let sessions = try await adapter.sessions()
        let zst = try #require(sessions.first { $0.transcriptURL.lastPathComponent.hasSuffix(".zst") })
        let items = try await TranscriptExport.items(for: [zst], adapters: [adapter], masksSecrets: true)
        #expect(items.count == 1)
        #expect(!items[0].transcript.messages.isEmpty)
    }

    @Test("Export file names and destinations")
    func exportDestination() throws {
        let session = makeSession("n1")
        #expect(TranscriptExport.fileName(for: [session], extension: "md") == "Session n1.md")
        #expect(TranscriptExport.fileName(for: [session, session], extension: "pdf") == "2 agent sessions.pdf")
        let folder = try TempFolder()
        let adapter = StubAdapter(kind: .claudeCode, root: folder.url.appendingPathComponent(".claude"), sessions: [])
        #expect(TranscriptExport.isInsideAgentFolder(folder.url.appendingPathComponent(".claude/projects/x.md"), adapters: [adapter]))
        #expect(!TranscriptExport.isInsideAgentFolder(folder.url.appendingPathComponent(".claude-notes/x.md"), adapters: [adapter]))
        #expect(!TranscriptExport.isInsideAgentFolder(folder.url.appendingPathComponent("Desktop/x.md"), adapters: [adapter]))
    }

    // MARK: Resume

    @Test("Resume commands per agent, in the project folder")
    func resumeCommands() throws {
        let id = "aaaaaaaa-1111-4111-8111-111111111111"
        let exists: (String) -> Bool = { $0 == "/Users/dev/code/orbit api" }
        func command(_ agent: AgentKind, project: String? = "/Users/dev/code/orbit api") throws -> ResumeCommand {
            try ResumeCommand.resolve(for: makeSession(id, agent: agent, project: project), folderExists: exists).get()
        }
        let claude = try command(.claudeCode)
        #expect(claude.executable == "claude")
        #expect(claude.arguments == ["--resume", id])
        #expect(claude.shellLine == "cd '/Users/dev/code/orbit api' && claude --resume \(id)")
        #expect(claude.script.contains("cd -- '/Users/dev/code/orbit api' || exit 1"))
        #expect(claude.script.contains("rm -f -- \"$0\""))
        #expect(try command(.codex).arguments == ["resume", id])
        #expect(try command(.codex, project: "/gone").directory == nil)
        #expect(try command(.gemini).arguments == ["--resume", id])
        #expect(try command(.qwen).executable == "qwen")
        #expect(try command(.openCode, project: nil).arguments == ["--session", id])
        #expect(try command(.copilot).arguments == ["--resume", id])
        #expect(try command(.aider).arguments == ["--restore-chat-history"])
    }

    @Test("Resume is refused with a reason")
    func resumeRefused() {
        let id = "aaaaaaaa-1111-4111-8111-111111111111"
        func reason(_ session: Session) -> ResumeCommand.Unavailable? {
            if case .failure(let why) = ResumeCommand.resolve(for: session, folderExists: { _ in false }) { return why }
            return nil
        }
        #expect(reason(makeSession(id, agent: .claudeCode, project: "/gone")) == .projectMissing("/gone"))
        #expect(reason(makeSession(id, agent: .claudeCode, project: nil)) == .noProject(.claudeCode))
        #expect(reason(makeSession(id, agent: .zed)) == .noCommand(.zed))
        #expect(reason(makeSession(id, agent: .vsCodeChat)) == .noCommand(.vsCodeChat))
        #expect(reason(makeSession("--help; rm -rf ~", agent: .codex)) == .unsafeID(.codex))
        #expect(reason(makeSession(id, agent: .codex, status: .live)) == .live(.codex))
        #expect(reason(makeSession(id, agent: .claudeCode, project: "/gone"))?.errorDescription?.contains("gone") == true)
    }

    // MARK: Scans

    @Test("One scan lists each agent once; Aider uses its project folders instead of a second scan")
    func aiderSingleScan() async throws {
        let fixture = try AiderFixtureHome()
        let other = StubAdapter(kind: .claudeCode, root: fixture.home.appendingPathComponent(".claude"),
                                sessions: [makeSession("c1", project: fixture.repo.path)])
        let aider = AiderAdapter(aiderHome: fixture.home.appendingPathComponent(".aider", isDirectory: true),
                                 discovery: AiderDiscovery.standard(home: fixture.home, others: [other], environment: [:]),
                                 openHandles: StubOpenHandleChecker(holders: []), processes: FixedProcessLister([]))
        let context = DomovyContext(home: fixture.home, isCustomHome: true, adapters: [other, aider], executor: Executor(storeRoot: fixture.storeRoot))
        let scans = await context.scanSessions()
        #expect(scans.map(\.adapter.kind) == [.claudeCode, .aider])
        #expect(scans.last?.sessions.first?.projectPath == fixture.repo.path)
        #expect(other.listCount == 1)
        let all = try await context.allSessions()
        #expect(all.count == 2)
        #expect(other.listCount == 2)
    }
}

