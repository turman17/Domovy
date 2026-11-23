import DomovyCore
import Foundation
import Testing

/// Model cleanups against fixture stores with stub CLIs. Everything executes into the
/// fixture's own quarantine, never the real Trash.
@Suite("Local model cleanups")
struct ModelCleanupTests {
    typealias D = ModelFixtureHome.Digests
    typealias F = ModelFixtureHome

    private static let ollamaServer = RunningProcess(pid: 811, name: "ollama")
    private static let lmStudio = RunningProcess(pid: 812, name: "LM Studio")

    // MARK: Ollama

    @Test("ollama rm runs, is permanent, and the check finds manifest and unshared layers gone")
    func ollamaCLIRemoval() async throws {
        let fixture = try ModelFixtureHome()
        let planner = fixture.planner()
        let removal = try await planner.modelRemovalPlan([try await fixture.model(.ollama, "qwen3:14b")])
        let plan = try #require(removal.plans.first)
        #expect(plan.commands.map(\.commandLine) == ["ollama rm qwen3:14b"])
        #expect(removal.isPermanent && !removal.isUndoable)
        #expect(plan.summary.hasPrefix("Ollama deletes it ("))
        #expect(plan.summary.hasSuffix("); Undo can't bring it back."))
        #expect(plan.remarks.first == "Re-download with ollama pull qwen3:14b.")
        #expect(removal.excluded.map(\.url.lastPathComponent) == [D.shared])
        #expect(removal.excluded.first?.reason == "Shared with deepcoder:14b; stays.")
        #expect(removal.summary.hasPrefix("Ollama deletes it ("))
        #expect(removal.canExecute)

        let entries = try await planner.execute(removal, with: fixture.executor())
        #expect(fixture.stubLog(".ollama/models/.stub-ollama.log").suffix(2) == ["ps", "rm qwen3:14b"])
        #expect(!fixture.exists(F.qwenManifest))
        #expect(D.qwenOwn.allSatisfy { !fixture.exists(fixture.blob($0)) })
        #expect(fixture.exists(fixture.blob(D.shared)))
        #expect(fixture.exists(F.deepcoderManifest))
        #expect(entries.first?.leftovers == [])
        #expect(entries.first?.irreversible == true)
        // Nothing to put back, so undo never offers it.
        #expect(try fixture.executor().undoLog.latestPending() == nil)
    }

    @Test("a sloppy ollama rm is caught: the layers it left are reported")
    func ollamaSloppy() async throws {
        let fixture = try ModelFixtureHome()
        try fixture.touch(".ollama/models/.stub-sloppy")
        let planner = fixture.planner()
        let removal = try await planner.modelRemovalPlan([try await fixture.model(.ollama, "qwen3:14b")])
        let entries = try await planner.execute(removal, with: fixture.executor())
        #expect(!fixture.exists(F.qwenManifest))
        let leftovers = entries.flatMap(\.leftovers)
        #expect(leftovers.count == 1)
        #expect(leftovers.first?.hasPrefix("4 of 4 layers of qwen3:14b (") == true)
        #expect(leftovers.first?.hasSuffix(") are still in blobs/.") == true)
    }

    @Test("a model loaded in Ollama is refused, at plan time and again right before running")
    func ollamaLoaded() async throws {
        let fixture = try ModelFixtureHome()
        try fixture.touch(".ollama/models/.stub-loaded", "qwen3:14b\n")
        let model = try await fixture.model(.ollama, "qwen3:14b")
        let blocked = try await fixture.planner().modelRemovalPlan([model])
        #expect(blocked.isBlocked)
        #expect(blocked.reasons == ["qwen3:14b is loaded in Ollama right now. Stop it with ollama stop qwen3:14b, then try again."])
        #expect(blocked.summary.hasPrefix("Nothing will change yet."))
        await #expect(throws: CleanupError.self) { try await fixture.planner().execute(blocked, with: fixture.executor()) }

        try FileManager.default.removeItem(at: fixture.url(".ollama/models/.stub-loaded"))
        let removal = try await fixture.planner().modelRemovalPlan([model])
        #expect(!removal.isBlocked)
        try fixture.touch(".ollama/models/.stub-loaded", "qwen3:14b\n")
        await #expect(throws: CleanupError.self) { try await fixture.planner().execute(removal, with: fixture.executor()) }
        #expect(fixture.exists(F.qwenManifest))
        #expect(!fixture.stubLog(".ollama/models/.stub-ollama.log").contains("rm qwen3:14b"))
    }

    @Test("with the server down, the manifest and unshared layers move and undo puts them back")
    func ollamaFallback() async throws {
        let fixture = try ModelFixtureHome()
        try fixture.touch(".ollama/models/.stub-server-down")
        let before = fixture.modificationDate(F.qwenManifest)
        let planner = fixture.planner()
        let removal = try await planner.modelRemovalPlan([try await fixture.model(.ollama, "qwen3:14b")], destination: .quarantine)
        let plan = try #require(removal.plans.first)
        #expect(plan.commands.isEmpty)
        #expect(Set(plan.moves.map(\.source.lastPathComponent)) == Set(["14b"] + D.qwenOwn))
        #expect(plan.mustNotBeRunning.map(\.appName) == ["Ollama"])
        #expect(removal.isUndoable)
        #expect(removal.summary.hasSuffix("to the Domovy quarantine folder. You can undo this."))

        let executor = fixture.executor()
        let entries = try await planner.execute(removal, with: executor)
        #expect(!fixture.exists(F.qwenManifest))
        #expect(fixture.exists(fixture.blob(D.shared)))
        _ = try executor.undo(try #require(entries.first))
        #expect(fixture.exists(F.qwenManifest))
        #expect(D.qwenOwn.allSatisfy { fixture.exists(fixture.blob($0)) })
        #expect(fixture.modificationDate(F.qwenManifest) == before)
    }

    @Test("the file fallback is refused while Ollama runs, and without a readable store")
    func ollamaFallbackRefusals() async throws {
        let fixture = try ModelFixtureHome()
        try fixture.touch(".ollama/models/.stub-server-down")
        let model = try await fixture.model(.ollama, "qwen3:14b")
        let running = try await fixture.planner(running: [Self.ollamaServer]).modelRemovalPlan([model])
        #expect(running.isBlocked)
        #expect(running.reasons.first?.hasPrefix("Ollama is running (ollama, pid 811).") == true)

        try fixture.touch(".ollama/models/manifests/registry.ollama.ai/library/qwen3/broken", "not json")
        let unknown = try await fixture.planner(ollama: ToolChoice.none).modelRemovalPlan([model])
        #expect(unknown.isBlocked)
        #expect(unknown.reasons.first?.hasPrefix("Some Ollama manifests are in a format Domovy does not know") == true)
    }

    @Test("removing two models that share a layer frees it exactly once")
    func ollamaSharedAmongSelection() async throws {
        let fixture = try ModelFixtureHome()
        let qwen = try await fixture.model(.ollama, "qwen3:14b")
        let deepcoder = try await fixture.model(.ollama, "deepcoder:14b")

        try fixture.touch(".ollama/models/.stub-server-down")
        let moved = try await fixture.planner().modelRemovalPlan([qwen, deepcoder], destination: .quarantine)
        let sources = moved.plans.flatMap(\.moves).map(\.source.lastPathComponent)
        #expect(sources.filter { $0 == D.shared }.count == 1)
        #expect(moved.excluded.isEmpty)
        #expect(moved.title == "Remove 2 models?")

        try FileManager.default.removeItem(at: fixture.url(".ollama/models/.stub-server-down"))
        let planner = fixture.planner()
        let removal = try await planner.modelRemovalPlan([qwen, deepcoder])
        #expect(removal.plans.first?.commands.count == 2)
        let entries = try await planner.execute(removal, with: fixture.executor())
        #expect(entries.flatMap(\.leftovers).isEmpty)
        #expect(!fixture.exists(fixture.blob(D.shared)))
    }

    @Test("orphaned blobs move, recent ones stay, open ones block, and undo restores them")
    func ollamaOrphans() async throws {
        let fixture = try ModelFixtureHome()
        let fresh = D.blob("f0")
        try fixture.touch(fixture.blob(fresh), "just downloaded")
        let planner = fixture.planner()
        let cleanup = try await planner.plan(.ollamaOrphanBlobs, destination: .quarantine)
        #expect(Set(cleanup.plan.moves.map(\.source.lastPathComponent)) == [D.orphan, D.partial])
        #expect(cleanup.excluded.map(\.url.lastPathComponent) == [fresh])
        #expect(cleanup.plan.mustNotBeRunning.isEmpty)
        #expect(cleanup.canExecute)

        // The server may run; it may not have the files open.
        let running = try await fixture.planner(running: [Self.ollamaServer]).plan(.ollamaOrphanBlobs)
        #expect(!running.isBlocked)
        let holder = OpenHandleHolder(pid: 811, processName: "ollama", path: fixture.url(fixture.blob(D.partial)).standardizedFileURL.path)
        let open = try await fixture.planner(running: [Self.ollamaServer], holders: [holder]).plan(.ollamaOrphanBlobs)
        #expect(open.isBlocked)
        #expect(open.plan.liveCheck.reasons.first == "ollama (pid 811) has a file open in \(D.partial).")

        let executor = fixture.executor()
        let entry = try await planner.execute(cleanup, with: executor)
        #expect(!fixture.exists(fixture.blob(D.orphan)))
        #expect(D.qwenOwn.allSatisfy { fixture.exists(fixture.blob($0)) })
        _ = try executor.undo(entry)
        #expect(fixture.exists(fixture.blob(D.orphan)) && fixture.exists(fixture.blob(D.partial)))
    }

    // MARK: LM Studio

    @Test("an LM Studio model folder moves; refused while LM Studio runs; undo puts it back")
    func lmStudio() async throws {
        let fixture = try ModelFixtureHome()
        let model = try await fixture.model(.lmStudio, "lmstudio-community/Qwen3-8B-GGUF")
        let blocked = try await fixture.planner(running: [Self.lmStudio]).modelRemovalPlan([model])
        #expect(blocked.reasons.first?.hasPrefix("LM Studio is running (LM Studio, pid 812).") == true)

        let planner = fixture.planner()
        let removal = try await planner.modelRemovalPlan([model], destination: .quarantine)
        #expect(removal.plans.first?.moves.map(\.source.lastPathComponent) == ["Qwen3-8B-GGUF"])
        let executor = fixture.executor()
        let entries = try await planner.execute(removal, with: executor)
        #expect(!fixture.exists(F.lmModel))
        #expect(fixture.exists(".lmstudio/settings.json"))
        _ = try executor.undo(try #require(entries.first))
        #expect(fixture.exists(F.lmModel + "/Qwen3-8B-Q4_K_M.gguf"))
    }

    // MARK: Hugging Face

    @Test("detached revisions move without breaking any kept snapshot; undo restores them")
    func detachedFallback() async throws {
        let fixture = try ModelFixtureHome()
        let planner = fixture.planner()
        let cleanup = try await planner.plan(.huggingFaceDetached, destination: .quarantine)
        let names = cleanup.plan.moves.map(\.source.lastPathComponent)
        #expect(names.filter { $0 == ModelFixtureHome.Revisions.detached }.count == 2)
        #expect(Set(names).isSuperset(of: [String(repeating: "b2", count: 20), String(repeating: "b3", count: 20)]))
        #expect(!names.contains(String(repeating: "b1", count: 20)))

        let executor = fixture.executor()
        let entry = try await planner.execute(cleanup, with: executor)
        #expect(!fixture.exists(F.tinyBert + "/snapshots/" + ModelFixtureHome.Revisions.detached))
        #expect(fixture.brokenLinks(in: F.tinyBert).isEmpty)
        #expect(fixture.brokenLinks(in: F.distilled).isEmpty)
        #expect(fixture.exists(F.tinyBert + "/snapshots/" + ModelFixtureHome.Revisions.main + "/config.json"))
        _ = try executor.undo(entry)
        #expect(fixture.exists(F.tinyBert + "/snapshots/" + ModelFixtureHome.Revisions.detached + "/model.safetensors"))
        #expect(fixture.brokenLinks(in: F.tinyBert).isEmpty)
    }

    @Test("hf cache prune is preferred when the CLI has it, and verified")
    func detachedCLI() async throws {
        let fixture = try ModelFixtureHome()
        let planner = fixture.planner(hf: nil)
        let cleanup = try await planner.plan(.huggingFaceDetached)
        #expect(cleanup.plan.commands.map(\.commandLine) == ["hf cache prune --yes"])
        #expect(cleanup.plan.commands.first?.environment["HF_HUB_CACHE"] == fixture.hub.standardizedFileURL.path)
        #expect(cleanup.summary.hasSuffix("Undo can't bring them back."))
        let entry = try await planner.execute(cleanup, with: fixture.executor())
        #expect(entry.leftovers.isEmpty)
        #expect(entry.irreversible)
        #expect(!fixture.exists(F.tinyBert + "/snapshots/" + ModelFixtureHome.Revisions.detached))
        #expect(fixture.brokenLinks(in: F.tinyBert).isEmpty)
        #expect(fixture.brokenLinks(in: F.distilled).isEmpty)
    }

    @Test("a sloppy hf cache prune is caught")
    func detachedCLISloppy() async throws {
        let fixture = try ModelFixtureHome()
        try fixture.touch(".cache/huggingface/hub/.stub-sloppy")
        let planner = fixture.planner(hf: nil)
        let entry = try await planner.execute(try await planner.plan(.huggingFaceDetached), with: fixture.executor())
        #expect(entry.leftovers.first?.hasPrefix("1 of 1 detached revisions (") == true)
    }

    @Test("a repo moves with the store files only it uses; a file another repo uses stays")
    func repoFallback() async throws {
        let fixture = try ModelFixtureHome()
        let planner = fixture.planner()
        let removal = try await planner.modelRemovalPlan([try await fixture.model(.huggingFace, "acme/tiny-bert")], destination: .quarantine)
        let moved = removal.plans.flatMap(\.moves).map(\.source.lastPathComponent)
        #expect(moved.contains("models--acme--tiny-bert"))
        #expect(moved.contains(String(repeating: "2", count: 64)) && moved.contains(String(repeating: "2", count: 64) + ".refs"))
        #expect(!moved.contains(String(repeating: "1", count: 64)))
        #expect(removal.excluded.map(\.reason) == ["Another repo uses it; stays."])

        let executor = fixture.executor()
        let entries = try await planner.execute(removal, with: executor)
        #expect(!fixture.exists(F.tinyBert))
        #expect(fixture.exists(F.sharedStoreFile))
        #expect(fixture.brokenLinks(in: F.distilled).isEmpty)
        _ = try executor.undo(try #require(entries.first))
        #expect(fixture.brokenLinks(in: F.tinyBert).isEmpty)
        #expect(fixture.exists(F.ownStoreFile))
    }

    @Test("both repos sharing a store file: it moves once")
    func repoSharedAmongSelection() async throws {
        let fixture = try ModelFixtureHome()
        let models = [try await fixture.model(.huggingFace, "acme/tiny-bert"), try await fixture.model(.huggingFace, "acme/tiny-bert-distilled")]
        let removal = try await fixture.planner().modelRemovalPlan(models, destination: .quarantine)
        let moved = removal.plans.flatMap(\.moves).map(\.source.lastPathComponent)
        #expect(moved.filter { $0 == String(repeating: "1", count: 64) }.count == 1)
        #expect(removal.excluded.isEmpty)
    }

    @Test("hf cache rm is preferred and verified; a sloppy one is reported")
    func repoCLI() async throws {
        let fixture = try ModelFixtureHome()
        let planner = fixture.planner(hf: nil)
        let model = try await fixture.model(.huggingFace, "acme/tiny-bert")
        let removal = try await planner.modelRemovalPlan([model])
        #expect(removal.plans.first?.commands.map(\.commandLine) == ["hf cache rm model/acme/tiny-bert --yes"])
        let entries = try await planner.execute(removal, with: fixture.executor())
        #expect(entries.flatMap(\.leftovers).isEmpty)
        #expect(!fixture.exists(F.tinyBert))
        #expect(fixture.exists(F.sharedStoreFile))
        #expect(!fixture.exists(F.ownStoreFile))
        #expect(fixture.brokenLinks(in: F.distilled).isEmpty)

        let sloppy = try ModelFixtureHome()
        try sloppy.touch(".cache/huggingface/hub/.stub-sloppy")
        let sloppyPlanner = sloppy.planner(hf: nil)
        let leftovers = try await sloppyPlanner.execute(
            try await sloppyPlanner.modelRemovalPlan([try await sloppy.model(.huggingFace, "acme/tiny-bert")]), with: sloppy.executor()
        ).flatMap(\.leftovers)
        #expect(leftovers.contains("models--acme--tiny-bert is still there."))
    }

    @Test("a repo with a file open is refused")
    func repoOpen() async throws {
        let fixture = try ModelFixtureHome()
        let path = fixture.url(F.tinyBert + "/blobs/" + String(repeating: "b1", count: 20)).standardizedFileURL.path
        let planner = fixture.planner(holders: [OpenHandleHolder(pid: 900, processName: "python3", path: path)])
        let removal = try await planner.modelRemovalPlan([try await fixture.model(.huggingFace, "acme/tiny-bert")])
        #expect(removal.isBlocked)
        #expect(removal.reasons.first == "python3 (pid 900) has a file open in models--acme--tiny-bert.")
    }

    // MARK: Mixed and parsing

    @Test("one sheet for several tools: permanent and undoable parts are both said")
    func mixedBatch() async throws {
        let fixture = try ModelFixtureHome()
        let planner = fixture.planner()
        let removal = try await planner.modelRemovalPlan([
            try await fixture.model(.ollama, "someuser/tinyllm:q4"),
            try await fixture.model(.lmStudio, "bartowski/Llama-3.2-1B-Instruct-GGUF"),
        ], destination: .quarantine)
        #expect(removal.plans.map(\.agent) == [.ollama, .lmStudio])
        #expect(removal.isPermanent && !removal.isUndoable)
        #expect(removal.summary.contains("Ollama deletes it ("))
        #expect(removal.summary.hasSuffix("to the Domovy quarantine folder. You can undo this."))
        let executor = fixture.executor()
        let entries = try await planner.execute(removal, with: executor)
        #expect(entries.count == 2)
        // Only the LM Studio part can be undone.
        let pending = try executor.undoLog.latestPendingBatch()
        #expect(pending.map(\.agent) == [.lmStudio])
    }

    @Test("an unknown model name is refused")
    func unknownModel() async throws {
        let fixture = try ModelFixtureHome()
        let ghost = LocalModel(agent: .ollama, name: "ghost:1b", url: fixture.url(".ollama"), sizeBytes: 0, date: nil, dateKind: .added)
        await #expect(throws: CleanupError.modelNotFound("ghost:1b")) { try await fixture.planner().modelRemovalPlan([ghost]) }
    }

    @Test("Ollama names and ps output")
    func parsing() {
        #expect(OllamaNames.canonical("qwen3") == "qwen3:latest")
        #expect(OllamaNames.canonical("library/qwen3:14b") == "qwen3:14b")
        #expect(OllamaNames.canonical("registry.ollama.ai/library/qwen3:14b") == "qwen3:14b")
        #expect(OllamaNames.canonical("someuser/tinyllm") == "someuser/tinyllm:latest")
        #expect(OllamaNames.parsePS("NAME  ID  SIZE  PROCESSOR  UNTIL\nqwen3:14b  bdbd  9.3 GB  100% GPU  4 minutes from now\n") == ["qwen3:14b"])
        #expect(OllamaNames.parsePS("Error: could not connect") == [])
    }
}
