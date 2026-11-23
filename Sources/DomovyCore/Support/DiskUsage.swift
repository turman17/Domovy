import Foundation

/// Bytes on disk and bytes of content for a file or folder. Measured from metadata only;
/// file contents are never read.
struct DiskUsage: Hashable, Sendable {
    /// Allocated on disk: what removing it would free. A sparse VM image counts what it uses.
    var allocated: Int64 = 0
    /// Sum of file lengths.
    var logical: Int64 = 0

    static let zero = DiskUsage()

    static func + (lhs: DiskUsage, rhs: DiskUsage) -> DiskUsage {
        DiskUsage(allocated: lhs.allocated + rhs.allocated, logical: lhs.logical + rhs.logical)
    }

    static func += (lhs: inout DiskUsage, rhs: DiskUsage) { lhs = lhs + rhs }

    private static let keys: Set<URLResourceKey> = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey,
    ]

    /// A file, or every regular file below a folder. Symlinks are not followed.
    static func measure(_ url: URL) -> DiskUsage {
        guard let values = try? url.resourceValues(forKeys: keys), values.isSymbolicLink != true else { return .zero }
        guard values.isDirectory == true else { return of(values) }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) else {
            return .zero
        }
        var total = DiskUsage.zero
        for case let child as URL in enumerator {
            guard let v = try? child.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            total += of(v)
        }
        return total
    }

    static func measure(_ urls: [URL]) -> DiskUsage {
        urls.reduce(.zero) { $0 + measure($1) }
    }

    private static func of(_ values: URLResourceValues) -> DiskUsage {
        DiskUsage(allocated: Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0), logical: Int64(values.fileSize ?? 0))
    }
}

/// Collects footprint categories and keeps track of what is already counted, so the
/// leftovers of a folder can go into a final "keep" row without counting anything twice.
struct FootprintBuilder {
    let agent: AgentKind
    let root: URL
    private(set) var categories: [Footprint.Category] = []
    private var claimed = Set<String>()

    init(agent: AgentKind, root: URL) {
        self.agent = agent
        self.root = root.standardizedFileURL
    }

    /// Adds a category covering `items` (only those that exist). Empty categories are left out.
    /// - Parameter url: the folder to reveal; defaults to the single item.
    mutating func add(
        _ name: String,
        _ items: [URL],
        reveal url: URL? = nil,
        _ disposition: Footprint.Disposition,
        _ note: String,
        guidance: Footprint.Guidance? = nil
    ) {
        let present = items.map(\.standardizedFileURL).filter { FileSystem.exists($0) && !claimed.contains($0.path) }
        claim(present)
        guard !present.isEmpty else { return }
        let usage = DiskUsage.measure(present)
        let primary = url ?? (present.count == 1 ? present[0] : present[0].deletingLastPathComponent())
        categories.append(Footprint.Category(
            name: name,
            url: primary,
            items: present.count == 1 && present[0] == primary ? [] : present,
            sizeBytes: usage.allocated,
            logicalBytes: usage.logical,
            disposition: disposition,
            note: note,
            guidance: guidance
        ))
    }

    mutating func add(
        _ name: String,
        _ item: URL,
        _ disposition: Footprint.Disposition,
        _ note: String,
        guidance: Footprint.Guidance? = nil
    ) {
        add(name, [item], disposition, note, guidance: guidance)
    }

    /// Adds a category for a measured part of some files (one table's share of a database).
    /// The caller claims the files once all their parts are added. Empty parts are left out.
    mutating func add(
        _ name: String,
        part usage: DiskUsage,
        of items: [URL],
        reveal url: URL,
        _ disposition: Footprint.Disposition,
        _ note: String,
        guidance: Footprint.Guidance? = nil
    ) {
        guard usage.allocated > 0 else { return }
        categories.append(Footprint.Category(
            name: name, url: url, items: items.filter { FileSystem.exists($0) }, sizeBytes: usage.allocated,
            logicalBytes: usage.logical, disposition: disposition, note: note, guidance: guidance
        ))
    }

    /// Marks items as counted elsewhere (or deliberately not shown).
    mutating func claim(_ items: [URL]) {
        for item in items { claimed.insert(item.standardizedFileURL.path) }
    }

    func isClaimed(_ url: URL) -> Bool {
        claimed.contains(url.standardizedFileURL.path)
    }

    /// Children of `folder` that no category has counted yet.
    func unclaimedChildren(of folder: URL) -> [URL] {
        FileSystem.children(of: folder).filter { !isClaimed($0) }
    }

    func build(models: [LocalModel] = []) -> Footprint {
        Footprint(agent: agent, root: root, categories: categories, models: models)
    }
}
