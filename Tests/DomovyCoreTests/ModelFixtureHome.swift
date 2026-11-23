import DomovyCore
import Foundation

/// A throwaway home with Ollama, LM Studio and the Hugging Face hub cache copied from
/// `Tests/Fixtures/{ollama,lmstudio,huggingface}/<version>/`, and the stub `ollama` and `hf`
/// CLIs in `<base>/bin`. Never the real stores or the real CLIs.
final class ModelFixtureHome: Sendable {
    enum Digests {
        static let qwenOwn = ["c1", "a1", "b1", "d1"].map(blob)
        static let shared = blob("5e")
        static let deepcoderOwn = ["c2", "a2", "b2", "d2"].map(blob)
        static let orphan = blob("0f")
        static let partial = blob("e5") + "-partial"
        static func blob(_ pair: String) -> String { "sha256-" + String(repeating: pair, count: 32) }
    }

    enum Revisions {
        static let main = String(repeating: "a", count: 40)
        static let detached = String(repeating: "d", count: 40)
        static let distilled = String(repeating: "e", count: 40)
    }

    static let qwenManifest = ".ollama/models/manifests/registry.ollama.ai/library/qwen3/14b"
    static let deepcoderManifest = ".ollama/models/manifests/registry.ollama.ai/library/deepcoder/14b"
    static let tinyBert = ".cache/huggingface/hub/models--acme--tiny-bert"
    static let distilled = ".cache/huggingface/hub/models--acme--tiny-bert-distilled"
    static let sharedStoreFile = ".cache/huggingface/hub/blobs/11/" + String(repeating: "1", count: 64)
    static let ownStoreFile = ".cache/huggingface/hub/blobs/22/" + String(repeating: "2", count: 64)
    static let lmModel = ".lmstudio/models/lmstudio-community/Qwen3-8B-GGUF"

    let home: URL
    let storeRoot: URL
    let ollamaStub: URL
    let hfStub: URL
    var stores: ModelStores { ModelStores.at(home: home, isCustomHome: true) }
    var ollamaModels: URL { url(".ollama/models") }
    var hub: URL { url(".cache/huggingface/hub") }

    init(old: Date = Date().addingTimeInterval(-90 * 86_400)) throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("domovy-model-tests-\(UUID().uuidString)", isDirectory: true)
        home = base.appendingPathComponent("home", isDirectory: true)
        storeRoot = base.appendingPathComponent("store", isDirectory: true)
        ollamaStub = base.appendingPathComponent("bin/ollama")
        hfStub = base.appendingPathComponent("bin/hf")
        let fixtures = FixtureHome.fixturesRoot
        try fm.createDirectory(at: home.appendingPathComponent(".cache", isDirectory: true), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("ollama/0.33/.ollama"), to: url(".ollama"))
        try fm.copyItem(at: fixtures.appendingPathComponent("lmstudio/0.3/.lmstudio"), to: url(".lmstudio"))
        try fm.createDirectory(at: url(".cache/huggingface"), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("huggingface/1.x/hub"), to: hub)
        try fm.createDirectory(at: ollamaStub.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: fixtures.appendingPathComponent("ollama/stub-ollama.sh"), to: ollamaStub)
        try fm.copyItem(at: fixtures.appendingPathComponent("huggingface/stub-hf.sh"), to: hfStub)
        // Everything is old, so the one-hour grace periods do not hold anything back.
        if let all = fm.enumerator(at: home, includingPropertiesForKeys: nil) {
            for case let item as URL in all { try? Self.setDate(old, of: item) }
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    /// Deterministic: fixed processes and open files, stub CLIs unless told otherwise.
    func planner(
        running: [RunningProcess]? = [],
        holders: [OpenHandleHolder]? = [],
        ollama: ToolChoice? = nil,
        hf: ToolChoice? = ToolChoice.none,
        stores custom: ModelStores? = nil,
        environment: [String: String] = [:],
        launchd: [String: String] = [:]
    ) -> CleanupPlanner {
        CleanupPlanner(
            claudeCodeRoot: url(".claude"), codexRoot: url(".codex"), desktopSupport: url("Library/Application Support/Claude"),
            models: custom ?? stores, ollamaCLI: ollama ?? .executable(ollamaStub), huggingFaceCLI: hf ?? .executable(hfStub),
            openHandles: PrefixOpenHandleChecker(holders: holders), processes: FixedProcessLister(running), environment: environment,
            launchdEnvironment: { launchd[$0] }
        )
    }

    func executor(running: [RunningProcess] = [], copier: QuarantineCopier = .system) -> Executor {
        Executor(storeRoot: storeRoot, processes: FixedProcessLister(running), copier: copier)
    }

    /// Nanosecond modification time, without following symlinks.
    func modificationTime(_ relative: String) -> [Int]? {
        var info = stat()
        guard lstat(url(relative).path, &info) == 0 else { return nil }
        return [info.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec]
    }

    func footprint(_ agent: AgentKind) async throws -> Footprint {
        switch agent {
        case .ollama: try await OllamaFootprint(stores: stores).footprint()
        case .lmStudio: try await LMStudioFootprint(stores: stores).footprint()
        default: try await HuggingFaceFootprint(stores: stores).footprint()
        }
    }

    func model(_ agent: AgentKind, _ name: String) async throws -> LocalModel {
        guard let model = try await footprint(agent).models.first(where: { $0.name == name }) else {
            throw CleanupError.modelNotFound(name)
        }
        return model
    }

    func url(_ relative: String) -> URL { home.appendingPathComponent(relative) }
    func blob(_ name: String) -> String { ".ollama/models/blobs/\(name)" }
    /// True for a file, folder or symlink (even a dangling one).
    func exists(_ relative: String) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url(relative).path)) != nil }
    func touch(_ relative: String, _ text: String = "") throws { try Data(text.utf8).write(to: url(relative)) }

    func stubLog(_ relative: String) -> [String] {
        ((try? String(contentsOf: url(relative), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    func modificationDate(_ relative: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url(relative).path))?[.modificationDate] as? Date
    }

    static func setDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// Every symlink below a repo's snapshots that does not resolve to a file. Empty means intact.
    func brokenLinks(in repo: String) -> [String] {
        let snapshots = url(repo).appendingPathComponent("snapshots")
        guard let all = FileManager.default.enumerator(at: snapshots, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        return all.compactMap { $0 as? URL }.filter {
            (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true && !FileManager.default.fileExists(atPath: $0.path)
        }.map(\.lastPathComponent)
    }
}
