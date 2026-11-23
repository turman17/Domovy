import DomovyCore
import Foundation
import Testing

@Suite("Local model footprints")
struct ModelFootprintTests {
    typealias D = ModelFixtureHome.Digests

    private static func names(_ category: Footprint.Category) -> Set<String> {
        Set((category.items.isEmpty ? [category.url] : category.items).map(\.lastPathComponent))
    }

    /// Bytes on disk of every regular file below a folder, symlinks not followed.
    private static func allocated(below folder: URL) -> Int64 {
        (FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])?.allObjects ?? [])
            .compactMap { ($0 as? URL).flatMap { try? $0.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]) } }
            .filter { $0.isRegularFile == true }
            .reduce(Int64(0)) { $0 + Int64($1.totalFileAllocatedSize ?? 0) }
    }

    @Test("Ollama: one row per model, shared layers apart, orphans and partial downloads safe")
    func ollama() async throws {
        let fixture = try ModelFixtureHome()
        let footprint = try await fixture.footprint(.ollama)
        #expect(footprint.models.map(\.name) == ["deepcoder:14b", "qwen3:14b", "someuser/tinyllm:q4"])
        #expect(footprint.models.map(\.id).contains("ollama:qwen3:14b"))

        let qwen = try #require(footprint.categories.first { $0.name == "qwen3:14b" })
        #expect(qwen.disposition == .consequences)
        #expect(qwen.guidance == .removeModel("ollama:qwen3:14b"))
        #expect(Self.names(qwen) == Set(["14b"] + D.qwenOwn))
        #expect(qwen.note.hasPrefix("Re-download needed to use it again (ollama pull qwen3:14b)."))
        #expect(qwen.note.contains("1 shared layer stays for other models."))

        let shared = try #require(footprint.categories.first { $0.name == "Shared layers" })
        #expect(Self.names(shared) == [D.shared])
        #expect(shared.disposition == .keep)

        let orphans = try #require(footprint.categories.first { $0.name == "Orphaned blobs" })
        #expect(orphans.disposition == .safe)
        #expect(orphans.cleanupID == .ollamaOrphanBlobs)
        #expect(Self.names(orphans) == [D.orphan, D.partial])

        let model = try #require(footprint.models.first { $0.name == "qwen3:14b" })
        #expect(model.dateKind == .added)
        #expect(model.isUnused(days: 60))
        #expect(!model.isUnused(days: 120))
        #expect(model.sharedBytes > 0)
        // Nothing is counted twice: the rows add up to the measured store.
        let other = footprint.categories.first { $0.name == "Other" }
        #expect(other.map(Self.names)?.contains("id_ed25519.pub") == true)
        #expect(footprint.totalBytes == Self.allocated(below: fixture.url(".ollama")))
    }

    @Test("Ollama: an unreadable manifest turns orphan detection off and says why")
    func ollamaUnknownManifest() async throws {
        let fixture = try ModelFixtureHome()
        try fixture.touch(".ollama/models/manifests/registry.ollama.ai/library/qwen3/broken", "{\"schemaVersion\":3}")
        let footprint = try await fixture.footprint(.ollama)
        #expect(!footprint.categories.contains { $0.name == "Orphaned blobs" })
        let unreadable = try #require(footprint.categories.first { $0.name == "Unreadable manifests" })
        #expect(unreadable.disposition == .keep)
        await #expect(throws: CleanupError.self) { try await fixture.planner().plan(.ollamaOrphanBlobs) }
    }

    @Test("LM Studio: one row per model folder; settings and runtimes are kept")
    func lmStudio() async throws {
        let fixture = try ModelFixtureHome()
        let footprint = try await fixture.footprint(.lmStudio)
        #expect(footprint.models.map(\.name).sorted() == ["bartowski/Llama-3.2-1B-Instruct-GGUF", "lmstudio-community/Qwen3-8B-GGUF"])
        #expect(footprint.models.allSatisfy { $0.dateKind == .modified && $0.sizeBytes > 0 })
        let other = try #require(footprint.categories.first { $0.name == "Other" })
        #expect(other.disposition == .keep)
        #expect(Self.names(other).isSuperset(of: ["settings.json", "extensions"]))
    }

    @Test("Hugging Face: repos, detached revisions safe, files shared between repos kept")
    func huggingFace() async throws {
        let fixture = try ModelFixtureHome()
        let footprint = try await fixture.footprint(.huggingFace)
        #expect(footprint.models.map(\.name) == ["dataset/acme/reviews", "acme/tiny-bert", "acme/tiny-bert-distilled"])

        let detached = try #require(footprint.categories.first { $0.name == "Detached revisions" })
        #expect(detached.disposition == .safe)
        #expect(detached.cleanupID == .huggingFaceDetached)
        // The detached snapshot, its .no_exist folder and the two blobs only it uses; not b1,
        // which the main revision uses too.
        #expect(Self.names(detached) == [ModelFixtureHome.Revisions.detached, String(repeating: "b2", count: 20), String(repeating: "b3", count: 20)])
        #expect(detached.items.count == 4)

        let shared = try #require(footprint.categories.first { $0.name == "Shared files" })
        #expect(shared.items.first?.lastPathComponent == String(repeating: "1", count: 64))

        let bert = try #require(footprint.models.first { $0.name == "acme/tiny-bert" })
        #expect(bert.detail == "2 revisions, 1 detached; 1 shared file stays for other repos")
        #expect(bert.sharedBytes > 0)
        #expect(bert.dateKind == .downloaded)
        let row = try #require(footprint.categories.first { $0.name == "acme/tiny-bert" })
        #expect(row.guidance == .removeModel("hf:acme/tiny-bert"))
        #expect(row.items.contains { $0.lastPathComponent == String(repeating: "2", count: 64) })
        // Every byte counted once: repo folders are not in Other, and the rows add up.
        let other = try #require(footprint.categories.first { $0.name == "Other" })
        #expect(!Self.names(other).contains { $0.hasPrefix("models--") || $0.hasPrefix("datasets--") })
        #expect(footprint.totalBytes == Self.allocated(below: fixture.hub))
    }

    @Test("a custom home never reads the environment's store overrides")
    func storesIgnoreEnvironmentForCustomHomes() {
        let home = URL(fileURLWithPath: "/tmp/fixture-home")
        let env = ["OLLAMA_MODELS": "/Volumes/Models/ollama", "HF_HUB_CACHE": "/Volumes/Models/hf"]
        let custom = ModelStores.at(home: home, isCustomHome: true, environment: env)
        #expect(custom.ollamaModels.path == "/tmp/fixture-home/.ollama/models")
        #expect(custom.huggingFaceHub.path == "/tmp/fixture-home/.cache/huggingface/hub")
        let real = ModelStores.at(home: home, isCustomHome: false, environment: env)
        #expect(real.ollamaModels.path == "/Volumes/Models/ollama")
        #expect(real.huggingFaceHub.path == "/Volumes/Models/hf")
        let hfHome = ModelStores.at(home: home, isCustomHome: false, environment: ["HF_HOME": "/Volumes/hf"])
        #expect(hfHome.huggingFaceHub.path == "/Volumes/hf/hub")
    }

    @Test("a missing store is not installed")
    func notInstalled() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-empty-\(UUID().uuidString)")
        let stores = ModelStores.at(home: empty, isCustomHome: true)
        await #expect(throws: AdapterError.notInstalled(.ollama)) { try await OllamaFootprint(stores: stores).footprint() }
        await #expect(throws: AdapterError.notInstalled(.lmStudio)) { try await LMStudioFootprint(stores: stores).footprint() }
        await #expect(throws: AdapterError.notInstalled(.huggingFace)) { try await HuggingFaceFootprint(stores: stores).footprint() }
    }
}
