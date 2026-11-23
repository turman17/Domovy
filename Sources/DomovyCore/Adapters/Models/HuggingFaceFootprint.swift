import Foundation

/// Disk use of the Hugging Face hub cache: one row per repo, detached revisions (safe), files
/// shared between repos, and the cache's own bookkeeping.
public struct HuggingFaceFootprint: FootprintProvider {
    public let kind: AgentKind = .huggingFace
    public let stores: ModelStores

    public init(stores: ModelStores) {
        self.stores = stores
    }

    var cache: HuggingFaceCache { HuggingFaceCache(hub: stores.huggingFaceHub) }

    public static let detachedNote = "Older revisions no branch or tag points at. Code that pins one of them downloads it again."

    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(stores.huggingFaceHub) else { throw AdapterError.notInstalled(kind) }
        let scan = cache.scan()
        var builder = FootprintBuilder(agent: kind, root: stores.huggingFaceHub)

        let detached = scan.repos.map { HuggingFaceCache.detachedParts(of: $0, scan: scan) }
        builder.add("Detached revisions", detached.flatMap(\.all), reveal: stores.huggingFaceHub, .safe, Self.detachedNote,
                    guidance: .cleanup(.huggingFaceDetached))

        let models = Self.models(in: scan, hub: stores.huggingFaceHub)
        for (repo, model) in zip(scan.repos, models) {
            let parts = HuggingFaceCache.repoParts(of: repo, hub: stores.huggingFaceHub, scan: scan)
            // The repo row counts what is not already under Detached revisions.
            builder.add(model.name, Self.unclaimedParts(of: repo, extra: Array(parts.items.dropFirst()), builder: builder),
                        reveal: repo.url, .consequences, model.note, guidance: .removeModel(model.id))
        }
        // Repo folders are covered by their rows (and the detached row) one level down.
        builder.claim(scan.repos.flatMap { repo in
            [repo.url] + ["snapshots", "blobs", ".no_exist"].map { repo.url.appendingPathComponent($0, isDirectory: true) }
        })
        let shared = scan.xetLinks.filter { $0.value.count > 1 }.keys.sorted().map { URL(fileURLWithPath: $0) }
        builder.add("Shared files", shared.flatMap { [$0] + HuggingFaceCache.companions(of: $0) }, reveal: stores.huggingFaceHub, .keep,
                    "Files more than one repo uses. They go with the last repo that uses them.")
        builder.add("Unknown folders", scan.unknown, reveal: stores.huggingFaceHub, .keep,
                    "Repo folders without the usual snapshots and blobs. Domovy leaves them alone.")
        let store = stores.huggingFaceHub.appendingPathComponent("blobs", isDirectory: true)
        var rest: [URL] = []
        for prefix in FileSystem.children(of: store) where FileSystem.isDirectory(prefix) { rest += builder.unclaimedChildren(of: prefix) }
        builder.claim(FileSystem.children(of: store).filter { FileSystem.isDirectory($0) } + [store])
        let locks = stores.huggingFaceHub.appendingPathComponent(".locks", isDirectory: true)
        rest += builder.unclaimedChildren(of: store) + builder.unclaimedChildren(of: locks)
        builder.claim([locks])
        rest += builder.unclaimedChildren(of: stores.huggingFaceHub)
        builder.add("Other", rest, reveal: stores.huggingFaceHub, .keep, "Locks and cache bookkeeping. Small, and the hub library needs them.")
        return builder.build(models: models)
    }

    /// A repo's own entries one level down, skipping what the detached row already counts.
    private static func unclaimedParts(of repo: HuggingFaceCache.Repo, extra: [URL], builder: FootprintBuilder) -> [URL] {
        var parts: [URL] = []
        for child in FileSystem.children(of: repo.url) {
            if FileSystem.isDirectory(child), ["snapshots", "blobs", ".no_exist"].contains(child.lastPathComponent) {
                parts += builder.unclaimedChildren(of: child)
            } else {
                parts.append(child)
            }
        }
        return parts + extra.filter { !builder.isClaimed($0) }
    }

    static func models(in scan: HuggingFaceCache.Scan, hub: URL) -> [LocalModel] {
        scan.repos.map { repo in
            let parts = HuggingFaceCache.repoParts(of: repo, hub: hub, scan: scan)
            let own = DiskUsage.measure(parts.items)
            let shared = DiskUsage.measure(parts.sharedStay)
            let n = repo.revisions.count, d = repo.detached.count
            var detail = "\(n) \(n == 1 ? "revision" : "revisions")"
            if d > 0 { detail += ", \(d) detached" }
            if !parts.sharedStay.isEmpty { detail += "; \(parts.sharedStay.count) shared \(parts.sharedStay.count == 1 ? "file stays" : "files stay") for other repos" }
            return LocalModel(
                agent: .huggingFace, name: repo.name, url: repo.url, sizeBytes: own.allocated, sharedBytes: shared.allocated,
                date: repo.revisions.compactMap(\.modificationDate).max(), dateKind: .downloaded, detail: detail
            )
        }
    }
}
