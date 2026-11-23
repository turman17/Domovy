import Foundation

/// Disk use of Ollama: one row per model (its manifest plus the blobs no other model uses),
/// shared layers, orphaned blobs, and the keys and settings Ollama needs.
public struct OllamaFootprint: FootprintProvider {
    public let kind: AgentKind = .ollama
    public let stores: ModelStores

    public init(stores: ModelStores) {
        self.stores = stores
    }

    var store: OllamaStore { OllamaStore(models: stores.ollamaModels) }

    public static let orphanNote = "Not used by any model: left by removed models or interrupted downloads."

    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(stores.ollamaModels) || FileSystem.isDirectory(stores.ollamaHome) else {
            throw AdapterError.notInstalled(kind)
        }
        let scan = store.scan()
        var builder = FootprintBuilder(agent: kind, root: stores.ollamaModels)
        let models = Self.models(in: scan, store: store)
        let users = scan.users
        for (manifest, model) in zip(scan.manifests, models) {
            let exclusive = manifest.blobNames.filter { users[$0]?.count == 1 }.map { store.blobs.appendingPathComponent($0) }
            builder.add(model.name, [manifest.url] + exclusive, reveal: manifest.url.deletingLastPathComponent(), .consequences,
                        model.note, guidance: .removeModel(model.id))
        }
        let shared = users.filter { $0.value.count > 1 }.keys.sorted().map { store.blobs.appendingPathComponent($0) }
        builder.add("Shared layers", shared, reveal: store.blobs, .keep,
                    "Layers more than one model uses. They go with the last model that uses them.")
        if scan.isReliable {
            builder.add("Orphaned blobs", scan.orphans, reveal: store.blobs, .safe, Self.orphanNote,
                        guidance: .cleanup(.ollamaOrphanBlobs))
        } else {
            builder.add("Unreadable manifests", scan.unreadable, reveal: store.manifests, .keep,
                        "\(scan.unreadable.count) \(scan.unreadable.count == 1 ? "manifest is" : "manifests are") not in a format Domovy knows, so it does not look for orphaned blobs.")
        }
        var rest = builder.unclaimedChildren(of: store.blobs)
        builder.claim([store.manifests, store.blobs, stores.ollamaModels])
        rest += builder.unclaimedChildren(of: stores.ollamaModels) + builder.unclaimedChildren(of: stores.ollamaHome)
        builder.add("Other", rest, reveal: stores.ollamaHome, .keep, "Keys, history and settings Ollama needs.")
        return builder.build(models: models)
    }

    /// One model per manifest, in the scan's order. Shared layers count for none of them.
    static func models(in scan: OllamaStore.Scan, store: OllamaStore) -> [LocalModel] {
        let users = scan.users
        return scan.manifests.map { manifest in
            var own = DiskUsage.measure(manifest.url)
            var shared = DiskUsage.zero
            for blob in manifest.blobNames {
                let usage = DiskUsage.measure(store.blobs.appendingPathComponent(blob))
                if users[blob]?.count == 1 { own += usage } else { shared += usage }
            }
            let sharing = manifest.blobNames.filter { (users[$0]?.count ?? 0) > 1 }.count
            return LocalModel(
                agent: .ollama, name: manifest.name, url: manifest.url, sizeBytes: own.allocated, sharedBytes: shared.allocated,
                date: manifest.modificationDate, dateKind: .added,
                detail: sharing == 0 ? nil : "\(sharing) shared \(sharing == 1 ? "layer stays" : "layers stay") for other models"
            )
        }
    }
}
