import Foundation

/// Disk use of LM Studio: one row per model folder (`models/<publisher>/<model>/`), plus the
/// settings, runtimes and extensions in `~/.lmstudio` it needs. Layout from LM Studio's docs
/// and third-party guides; not verified on a real install yet.
public struct LMStudioFootprint: FootprintProvider {
    public let kind: AgentKind = .lmStudio
    public let stores: ModelStores

    public init(stores: ModelStores) {
        self.stores = stores
    }

    public func footprint() async throws -> Footprint {
        let modelRoots = stores.lmStudioModels.filter { FileSystem.isDirectory($0) }
        let hasHome = FileSystem.isDirectory(stores.lmStudioHome)
        guard hasHome || !modelRoots.isEmpty else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: hasHome ? stores.lmStudioHome : modelRoots[0])
        let models = Self.models(in: modelRoots)
        for model in models {
            builder.add(model.name, [model.url], .consequences, model.consequence, guidance: .removeModel(model.id))
        }
        var rest: [URL] = []
        for root in modelRoots {
            for publisher in FileSystem.children(of: root) { rest += builder.unclaimedChildren(of: publisher) }
            builder.claim(FileSystem.children(of: root))
            rest += builder.unclaimedChildren(of: root)
            builder.claim([root])
        }
        rest += builder.unclaimedChildren(of: stores.lmStudioHome)
        builder.add("Other", rest, reveal: hasHome ? stores.lmStudioHome : modelRoots[0], .keep,
                    "Settings, runtimes, extensions and sign-in LM Studio needs.")
        return builder.build(models: models)
    }

    /// Every `<publisher>/<model>` entry below the model folders.
    static func models(in roots: [URL]) -> [LocalModel] {
        roots.flatMap { root in
            FileSystem.children(of: root).filter { FileSystem.isDirectory($0) }.flatMap { publisher in
                FileSystem.children(of: publisher).filter { $0.lastPathComponent != ".DS_Store" }.map { folder in
                    LocalModel(
                        agent: .lmStudio,
                        name: "\(publisher.lastPathComponent)/\(folder.lastPathComponent)",
                        url: folder,
                        sizeBytes: DiskUsage.measure(folder).allocated,
                        date: newestModification(in: folder),
                        dateKind: .modified
                    )
                }
            }
        }
    }

    /// The newest modification time of the folder or any file in it.
    static func newestModification(in url: URL) -> Date? {
        var newest = FileSystem.modificationDate(of: url)
        guard FileSystem.isDirectory(url),
              let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return newest }
        for case let child as URL in enumerator {
            if let date = FileSystem.modificationDate(of: child), newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }
}
