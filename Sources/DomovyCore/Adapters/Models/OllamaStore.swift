import Foundation

/// Ollama's content-addressed store (`~/.ollama/models`, verified on Ollama 0.33.3):
/// `manifests/<registry>/<namespace>/<model>/<tag>` are small JSON files (schemaVersion 2,
/// a `config` and `layers`, each with `digest`, `mediaType`, `size`); `blobs/sha256-<hex>` hold
/// the content. Only manifests are read, and of them only the digests.
struct OllamaStore: Sendable {
    let models: URL

    var manifests: URL { models.appendingPathComponent("manifests", isDirectory: true) }
    var blobs: URL { models.appendingPathComponent("blobs", isDirectory: true) }

    static let defaultRegistry = "registry.ollama.ai"
    static let defaultNamespace = "library"
    /// Ollama's own grace period: the server leaves blobs younger than this alone while pruning.
    static let blobGracePeriod: TimeInterval = 3_600

    struct Manifest: Hashable, Sendable {
        let name: String
        let url: URL
        /// Blob file names (`sha256-<hex>`) of the config and every layer.
        let blobNames: [String]
        let modificationDate: Date?
    }

    struct Scan: Sendable {
        let manifests: [Manifest]
        /// Files under `manifests/` Domovy could not read as a manifest. While any exist,
        /// nothing is called unshared or orphaned: they may reference any blob.
        let unreadable: [URL]
        let blobFiles: [URL]

        /// Model names per blob file name.
        var users: [String: Set<String>] {
            var result: [String: Set<String>] = [:]
            for manifest in manifests {
                for blob in manifest.blobNames { result[blob, default: []].insert(manifest.name) }
            }
            return result
        }

        var isReliable: Bool { unreadable.isEmpty }

        /// Blobs no manifest references: leftovers of removed models or interrupted pulls.
        var orphans: [URL] {
            guard isReliable else { return [] }
            let used = users
            return blobFiles.filter { used[$0.lastPathComponent] == nil }
        }

        func manifest(named name: String) -> Manifest? {
            let wanted = OllamaStore.canonical(name)
            return manifests.first { $0.name == wanted }
        }
    }

    func scan() -> Scan {
        var found: [Manifest] = []
        var unreadable: [URL] = []
        let base = manifests.standardizedFileURL.pathComponents.count
        if let enumerator = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]) {
            for case let url as URL in enumerator {
                let file = url.standardizedFileURL
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                if file.lastPathComponent == ".DS_Store" { continue }
                let parts = Array(file.pathComponents.dropFirst(base))
                guard parts.count == 4, let manifest = Self.read(file, parts: parts) else {
                    unreadable.append(file)
                    continue
                }
                found.append(manifest)
            }
        }
        let blobFiles = FileSystem.children(of: blobs).filter {
            $0.lastPathComponent != ".DS_Store" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
        return Scan(manifests: found.sorted { $0.name < $1.name }, unreadable: unreadable, blobFiles: blobFiles)
    }

    /// The manifest's digests, or `nil` when it is not the schema Domovy knows.
    private static func read(_ url: URL, parts: [String]) -> Manifest? {
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["schemaVersion"] as? Int == 2,
              let config = json["config"] as? [String: Any],
              let layers = json["layers"] as? [[String: Any]] else { return nil }
        var names: [String] = []
        for entry in [config] + layers {
            guard let digest = entry["digest"] as? String, let name = blobName(digest) else { return nil }
            names.append(name)
        }
        return Manifest(name: name(parts), url: url, blobNames: names, modificationDate: FileSystem.modificationDate(of: url))
    }

    /// `sha256:<hex>` to the blob file name `sha256-<hex>`.
    static func blobName(_ digest: String) -> String? {
        let pieces = digest.split(separator: ":")
        guard pieces.count == 2, pieces[0] == "sha256", pieces[1].count == 64,
              pieces[1].allSatisfy({ $0.isHexDigit }) else { return nil }
        return "sha256-\(pieces[1])"
    }

    /// The name `ollama list` shows: `qwen3:14b`, `user/model:tag`, `host/ns/model:tag`.
    static func name(_ parts: [String]) -> String {
        let (registry, namespace, model, tag) = (parts[0], parts[1], parts[2], parts[3])
        if registry == defaultRegistry {
            return namespace == defaultNamespace ? "\(model):\(tag)" : "\(namespace)/\(model):\(tag)"
        }
        return "\(registry)/\(namespace)/\(model):\(tag)"
    }

    /// `qwen3` and `library/qwen3:latest` both mean `qwen3:latest`.
    static func canonical(_ name: String) -> String {
        let last = name.split(separator: "/").last ?? ""
        var rest = last.contains(":") ? name : name + ":latest"
        if rest.hasPrefix("\(defaultRegistry)/") { rest.removeFirst(defaultRegistry.count + 1) }
        if rest.hasPrefix("\(defaultNamespace)/"), rest.split(separator: "/").count == 2 { rest.removeFirst(defaultNamespace.count + 1) }
        return rest
    }
}
