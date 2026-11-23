import Darwin
@testable import DomovyCore
import Foundation
import Testing

/// Copies kept before a tool deletes for good, the Ollama store check, and mapped files.
@Suite("Kept copies and safety hardening")
struct KeptCopyTests {
    typealias D = ModelFixtureHome.Digests
    typealias F = ModelFixtureHome

    struct Refused: LocalizedError {
        var errorDescription: String? { "refused for the test" }
    }

    private static let noClone = QuarantineCopier(clone: { _, _ in throw Refused() }, copy: QuarantineCopier.copyItem)
    private static let nothingWorks = QuarantineCopier(clone: { _, _ in throw Refused() }, copy: { _, _ in throw Refused() })

    @Test("when APFS cannot clone, a full copy is kept, the entry says so, and undo still works")
    func copyFallback() async throws {
        let fixture = try ModelFixtureHome()
        let planner = fixture.planner()
        let executor = fixture.executor(copier: Self.noClone)
        let entries = try await planner.execute(try await planner.modelRemovalPlan([try await fixture.model(.ollama, "qwen3:14b")]), with: executor)
        let entry = try #require(entries.first)
        #expect(!fixture.exists(F.qwenManifest))
        #expect(entry.moved.allSatisfy { $0.kept?.method == .copy })
        #expect(entry.notes.count == 5)
        #expect(entry.notes.first?.contains("so Domovy kept a full copy") == true)
        _ = try executor.undo(entry)
        #expect(fixture.exists(F.qwenManifest))
        #expect(D.qwenOwn.allSatisfy { fixture.exists(fixture.blob($0)) })
    }

    @Test("when neither a clone nor a copy works, the command never runs")
    func bothFail() async throws {
        let fixture = try ModelFixtureHome()
        let planner = fixture.planner()
        let executor = fixture.executor(copier: Self.nothingWorks)
        let removal = try await planner.modelRemovalPlan([try await fixture.model(.ollama, "qwen3:14b")])
        await #expect {
            try await planner.execute(removal, with: executor)
        } throws: { error in
            guard case ExecutorError.copyFailed(_, let command, _) = error else { return false }
            return command == "ollama rm qwen3:14b"
        }
        #expect(!fixture.stubLog(".ollama/models/.stub-ollama.log").contains("rm qwen3:14b"))
        #expect(fixture.exists(F.qwenManifest))
        #expect(D.qwenOwn.allSatisfy { fixture.exists(fixture.blob($0)) })
        let quarantine = executor.quarantineDirectory
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: quarantine.path)) ?? []
        #expect(leftovers.allSatisfy { !$0.contains("copy-") })
    }

    @Test("a permanent command that names no files is refused")
    func nothingToKeep() throws {
        let fixture = try ModelFixtureHome()
        let command = PlannedCommand(executable: fixture.ollamaStub, arguments: ["rm", "qwen3:14b"],
                                     environment: ["OLLAMA_MODELS": fixture.ollamaModels.path], note: "Runs ollama rm.", isPermanent: true)
        let plan = Plan(agent: .ollama, sessionID: "qwen3:14b", action: .delete, destination: nil, moves: [], indexEdits: [],
                        commands: [command], liveCheck: LiveCheckResult(isLive: false, reasons: [], checkedSignals: [], openHandles: .clear))
        #expect(throws: ExecutorError.self) { try fixture.executor().execute(plan) }
        #expect(fixture.exists(F.qwenManifest))
        #expect(!fixture.stubLog(".ollama/models/.stub-ollama.log").contains("rm qwen3:14b"))
    }

    @Test("a folder and a file inside it are kept once")
    func filesToKeep() {
        let root = URL(fileURLWithPath: "/tmp/hub")
        let command = PlannedCommand(
            executable: root, arguments: [], note: "",
            copiesBeforeRun: [root.appendingPathComponent("blobs/x/1"), root.appendingPathComponent("models--a")],
            verifications: [.fileGone(root.appendingPathComponent("models--a")), .filesGone([root.appendingPathComponent("blobs/x")], what: "")],
            isPermanent: true
        )
        #expect(Executor.filesToKeep(command).map(\.path) == ["/tmp/hub/models--a", "/tmp/hub/blobs/x"])
    }

    // MARK: Ollama store

    @Test("OLLAMA_MODELS set or a store outside ~/.ollama/models: files move instead of ollama rm")
    func ollamaStoreMismatch() async throws {
        let fixture = try ModelFixtureHome()
        let model = try await fixture.model(.ollama, "qwen3:14b")
        let fromEnvironment = try await fixture.planner(environment: ["OLLAMA_MODELS": "/Volumes/External/ollama"]).modelRemovalPlan([model], destination: .quarantine)
        let moved = try #require(fromEnvironment.plans.first)
        #expect(moved.commands.isEmpty)
        #expect(Set(moved.moves.map(\.source.lastPathComponent)) == Set(["14b"] + D.qwenOwn))
        #expect(moved.mustNotBeRunning.map(\.appName) == ["Ollama"])
        #expect(moved.remarks.first?.hasPrefix("Ollama's server may use another models folder than the one Domovy scanned") == true)

        let elsewhere = ModelStores(ollamaHome: fixture.url(".ollama-config"), ollamaModels: fixture.ollamaModels,
                                    lmStudioHome: fixture.url(".lmstudio"), lmStudioModels: [], huggingFaceHub: fixture.hub)
        let custom = try await fixture.planner(stores: elsewhere).modelRemovalPlan([model])
        #expect(custom.plans.first?.commands.isEmpty == true)
        #expect(!fixture.stubLog(".ollama/models/.stub-ollama.log").contains("ps"))

        // While Ollama runs, the fallback refuses.
        let running = try await fixture.planner(running: [RunningProcess(pid: 811, name: "ollama")], environment: ["OLLAMA_MODELS": "/x"]).modelRemovalPlan([model])
        #expect(running.isBlocked)
    }

    // MARK: Undo log

    @Test("entries written before kept copies still decode")
    func oldEntriesDecode() throws {
        let fixture = try ModelFixtureHome()
        let undo = fixture.storeRoot.appendingPathComponent("Undo", isDirectory: true)
        try FileManager.default.createDirectory(at: undo, withIntermediateDirectories: true)
        let json = """
        {"id":"6F1D7D0E-4C55-4E43-9B5F-1C0C7E0B9A11","createdAt":"2026-10-01T10:00:00Z","planID":"0B0E2C3A-8E6F-4B9B-A0E3-5D7A0D1E2F33",
         "action":"delete","agent":"ollama","sessionID":"qwen3:14b","irreversible":true,
         "moved":[{"original":"file:///tmp/a","current":"file:///tmp/b"}],
         "undoCommands":[{"executable":"file:///opt/homebrew/bin/ollama","arguments":["rm","qwen3:14b"],"note":"Runs ollama rm qwen3:14b."}]}
        """
        try Data(json.utf8).write(to: undo.appendingPathComponent("2026-10-01T10-00-00Z-6F1D7D0E-4C55-4E43-9B5F-1C0C7E0B9A11.json"))
        let entry = try #require(try fixture.executor().undoLog.entries().first)
        #expect(entry.irreversible && !entry.isUndoable)
        #expect(entry.notes.isEmpty)
        #expect(entry.moved.first?.kept == nil)
        #expect(entry.undoCommands.first?.isPermanent == false)
        #expect(try fixture.executor().purgePlan([.toolCopy]).isEmpty)
    }

    // MARK: Mapped files

    @Test("a memory-mapped file counts as open after its descriptor is closed")
    func mappedFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-mmap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appendingPathComponent("weights.bin")
        let large = dir.appendingPathComponent("large.bin")
        try Data(count: 1 << 16).write(to: small)
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        #expect(truncate(large.path, off_t(LibprocOpenHandleChecker.mappedFileThreshold)) == 0)

        let mapped = try [small, large].map { url in
            let fd = open(url.path, O_RDONLY)
            try #require(fd >= 0)
            defer { close(fd) }
            let address = mmap(nil, 1 << 16, PROT_READ, MAP_SHARED, fd, 0)
            try #require(address != MAP_FAILED)
            return address
        }
        defer { for address in mapped { munmap(address, 1 << 16) } }

        let checker = LibprocOpenHandleChecker(cacheLifetime: 0)
        let me = getpid()
        let withMaps = try #require(await checker.holders(of: [small], includingMapped: true))
        #expect(withMaps.contains { $0.pid == me })
        let descriptorsOnly = try #require(await checker.holders(of: [small], includingMapped: false))
        #expect(!descriptorsOnly.contains { $0.pid == me })
        // A large file is looked for among mappings without being asked.
        let automatic = try #require(await checker.holders(of: [large]))
        #expect(automatic.contains { $0.pid == me })
        #expect(LibprocOpenHandleChecker.mayBeMapped(large) && !LibprocOpenHandleChecker.mayBeMapped(small))
    }
}
