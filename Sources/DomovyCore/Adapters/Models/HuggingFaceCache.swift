import Foundation

/// The Hugging Face hub cache (`~/.cache/huggingface/hub`, verified with huggingface_hub's
/// Xet layout on 2026-11-23): one `<type>s--<org>--<name>/` per repo with `refs/<branch>`
/// (a commit hash), `snapshots/<commit>/` (symlinks into the repo's `blobs/`) and `blobs/`
/// (files, or symlinks into the shared `hub/blobs/<xx>/<hash>` Xet store). Only refs and
/// symlink targets are read, never file contents.
struct HuggingFaceCache: Sendable {
    let hub: URL

    /// Blobs written within this window may belong to a download in progress.
    static let gracePeriod: TimeInterval = 3_600

    struct Revision: Hashable, Sendable {
        let commit: String
        let url: URL
        /// No ref points at it: an older download that `hf cache prune` would remove.
        let isDetached: Bool
        /// Names of the files in the repo's `blobs/` its symlinks point at.
        let blobs: Set<String>
        let modificationDate: Date?
    }

    struct Repo: Hashable, Sendable {
        let url: URL
        /// "model", "dataset" or "space".
        let type: String
        /// `Qwen/Qwen3-0.6B`.
        let repoID: String
        let revisions: [Revision]
        /// Entries of the repo's `blobs/`.
        let blobs: [URL]

        /// The name Domovy shows and `domo models rm` takes: the id for models, `dataset/<id>` else.
        var name: String { type == "model" ? repoID : "\(type)/\(repoID)" }
        /// The argument `hf cache rm` takes (assumed from the docs: `model/<id>`).
        var cliArgument: String { "\(type)/\(repoID)" }
        var detached: [Revision] { revisions.filter(\.isDetached) }
        var kept: [Revision] { revisions.filter { !$0.isDetached } }
    }

    struct Scan: Sendable {
        let repos: [Repo]
        /// Folders that look like repos but miss `snapshots/` or `blobs/`. Left alone.
        let unknown: [URL]
        /// Shared Xet store target path to the repo blob paths that link to it, across repos.
        let xetLinks: [String: Set<String>]

        /// The shared-store file a repo blob links to, if it is a symlink into `hub/blobs/`.
        func xetTarget(of blob: URL) -> URL? {
            guard let target = HuggingFaceCache.symlinkTarget(blob) else { return nil }
            return xetLinks[target.path] == nil ? nil : target
        }

        func isShared(_ target: URL) -> Bool { (xetLinks[target.path]?.count ?? 0) > 1 }

        func repo(named name: String) -> Repo? { repos.first { $0.name == name } }
    }

    func scan() -> Scan {
        var repos: [Repo] = []
        var unknown: [URL] = []
        for folder in FileSystem.children(of: hub) where FileSystem.isDirectory(folder) {
            let parts = folder.lastPathComponent.components(separatedBy: "--")
            guard parts.count >= 3, ["models", "datasets", "spaces"].contains(parts[0]) else { continue }
            let snapshots = folder.appendingPathComponent("snapshots", isDirectory: true)
            let blobs = folder.appendingPathComponent("blobs", isDirectory: true)
            guard FileSystem.isDirectory(snapshots), FileSystem.isDirectory(blobs) else {
                unknown.append(folder)
                continue
            }
            let referenced = Set(Self.refs(in: folder.appendingPathComponent("refs", isDirectory: true)))
            let revisions = FileSystem.children(of: snapshots).filter { FileSystem.isDirectory($0) }.map { snapshot in
                Revision(commit: snapshot.lastPathComponent, url: snapshot,
                         isDetached: !referenced.contains(snapshot.lastPathComponent),
                         blobs: Self.linkedBlobs(in: snapshot, repo: folder), modificationDate: FileSystem.modificationDate(of: snapshot))
            }
            repos.append(Repo(url: folder, type: String(parts[0].dropLast()), repoID: parts.dropFirst().joined(separator: "/"),
                              revisions: revisions, blobs: FileSystem.children(of: blobs)))
        }
        var links: [String: Set<String>] = [:]
        let store = hub.appendingPathComponent("blobs", isDirectory: true).standardizedFileURL.path + "/"
        for repo in repos {
            for blob in repo.blobs {
                guard let target = Self.symlinkTarget(blob), target.path.hasPrefix(store) else { continue }
                links[target.path, default: []].insert(blob.path)
            }
        }
        return Scan(repos: repos, unknown: unknown, xetLinks: links)
    }

    /// Commit hashes in `refs/` (branches, and `refs/pr/<n>` style subfolders).
    static func refs(in folder: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return enumerator.compactMap { item -> String? in
            guard let url = item as? URL, (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url), data.count <= 128 else { return nil }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
    }

    /// Names of the repo blobs the symlinks below a snapshot point at. Matched by name below
    /// `<repo>/blobs/`, so `/var` versus `/private/var` spellings of the same folder agree.
    static func linkedBlobs(in snapshot: URL, repo: URL) -> Set<String> {
        guard let enumerator = FileManager.default.enumerator(at: snapshot, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        var result = Set<String>()
        for case let url as URL in enumerator {
            guard let target = symlinkTarget(url) else { continue }
            let folder = target.deletingLastPathComponent()
            if folder.lastPathComponent == "blobs", folder.deletingLastPathComponent().lastPathComponent == repo.lastPathComponent {
                result.insert(target.lastPathComponent)
            }
        }
        return result
    }

    /// Where a symlink points, resolved one level against its folder; `nil` for anything else.
    /// Resolved by text only: `standardizedFileURL` follows symlinks once a path has `..` in
    /// it, which would turn a repo blob link into its Xet store target.
    static func symlinkTarget(_ url: URL) -> URL? {
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true,
              let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return nil }
        let base = destination.hasPrefix("/") ? [] : url.deletingLastPathComponent().path.split(separator: "/").map(String.init)
        var parts: [String] = base
        for part in destination.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"))
    }

    /// Bytes on disk of a repo blob: the file itself, or the Xet store file it links to.
    static func usage(of blob: URL, scan: Scan) -> DiskUsage {
        scan.xetTarget(of: blob).map { DiskUsage.measure($0) } ?? DiskUsage.measure(blob)
    }

    /// The `.refs` and `.lock` files next to a shared-store file; they go and come back with it.
    static func companions(of target: URL) -> [URL] {
        [target.appendingPathExtension("refs"), target.appendingPathExtension("lock")].filter { FileSystem.exists($0) }
    }

    /// What removing a repo's detached revisions takes: their snapshot folders, the repo blobs
    /// only they use (or nothing uses, past the grace period), and the shared-store files only
    /// those blobs link to. Blobs a kept revision uses always stay.
    struct DetachedParts: Sendable {
        var snapshots: [URL] = []
        var blobs: [URL] = []
        var storeFiles: [URL] = []
        /// Unused blobs left alone because they are new (a download may be running).
        var recent: [URL] = []
        var all: [URL] { snapshots + blobs + storeFiles }
    }

    static func detachedParts(of repo: Repo, scan: Scan, now: Date = Date()) -> DetachedParts {
        var parts = DetachedParts()
        let keptBlobs = repo.kept.reduce(into: Set<String>()) { $0.formUnion($1.blobs) }
        let usedBlobs = repo.revisions.reduce(into: Set<String>()) { $0.formUnion($1.blobs) }
        parts.snapshots = repo.detached.map(\.url)
        let noExist = repo.url.appendingPathComponent(".no_exist", isDirectory: true)
        parts.snapshots += repo.detached.map { noExist.appendingPathComponent($0.commit, isDirectory: true) }.filter { FileSystem.exists($0) }
        for blob in repo.blobs where !keptBlobs.contains(blob.lastPathComponent) {
            if !usedBlobs.contains(blob.lastPathComponent) {
                // Used by no revision at all: an interrupted download unless it is old.
                let date = FileSystem.modificationDate(of: blob) ?? now
                if blob.pathExtension == "incomplete" || now.timeIntervalSince(date) < gracePeriod {
                    parts.recent.append(blob)
                    continue
                }
            }
            parts.blobs.append(blob)
            if let target = scan.xetTarget(of: blob), !scan.isShared(target) {
                parts.storeFiles.append(target)
                parts.storeFiles += companions(of: target)
            }
        }
        return parts
    }

    /// Everything removing the whole repo takes: its folder, its lock folder, and the
    /// shared-store files no other repo links to.
    static func repoParts(of repo: Repo, hub: URL, scan: Scan) -> (items: [URL], sharedStay: [URL]) {
        var items = [repo.url]
        let locks = hub.appendingPathComponent(".locks/\(repo.url.lastPathComponent)", isDirectory: true)
        if FileSystem.exists(locks) { items.append(locks) }
        var shared: [URL] = []
        for blob in repo.blobs {
            guard let target = scan.xetTarget(of: blob) else { continue }
            if scan.isShared(target) { shared.append(target) } else { items += [target] + companions(of: target) }
        }
        return (items, shared)
    }
}
