import Foundation

/// Finds build output folders near the top of a checkout. Never follows symlinks, never enters
/// `.git`, hidden folders, nested repositories or worktrees, or a folder it already matched.
/// In a git checkout a folder counts only when git ignores it and tracks nothing in it, so the
/// project's sources are never offered.
struct BuildOutputFinder: Sendable {
    let git: GitReader
    /// How deep below the checkout to look in a repository (monorepo packages sit at 2 or 3).
    var gitDepth = 3
    /// A folder that is not a repository is only looked at directly, since it may be `~/Documents`.
    var plainDepth = 1
    /// Upper bound on folders listed per checkout, so a huge tree cannot stall the scan.
    var maxFolders = 4000

    func find(in checkout: URL, isGit: Bool) -> [(url: URL, kind: BuildOutputKind)] {
        let maxDepth = isGit ? gitDepth : plainDepth
        var found: [(url: URL, kind: BuildOutputKind)] = []
        var queue: [(url: URL, depth: Int)] = [(checkout, 0)]
        var listed = 0
        while !queue.isEmpty, listed < maxFolders {
            let (folder, depth) = queue.removeFirst()
            listed += 1
            for child in Self.subfolders(of: folder) {
                let name = child.lastPathComponent
                if let kind = BuildOutputKind(rawValue: name), Self.qualifies(kind, child, isGit: isGit),
                   !isGit || git.isIgnoredAndUntracked(child, in: checkout) {
                    found.append((child, kind))
                    continue
                }
                guard depth + 1 < maxDepth, !name.hasPrefix("."), !FileManager.default.fileExists(atPath: child.appendingPathComponent(".git").path) else { continue }
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    /// Real folders only; a symlink is never followed or offered.
    static func subfolders(of folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
        return items.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.map(\.standardizedFileURL).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The name alone is not enough for the ambiguous ones: `target`, `dist` and `.build` must sit
    /// next to the project file of the tool that makes them.
    static func qualifies(_ kind: BuildOutputKind, _ folder: URL, isGit: Bool) -> Bool {
        let parent = folder.deletingLastPathComponent()
        func sibling(_ name: String) -> Bool { FileManager.default.fileExists(atPath: parent.appendingPathComponent(name).path) }
        func inside(_ name: String) -> Bool { FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path) }
        switch kind {
        case .nodeModules, .pythonCache: return true
        case .swiftBuild: return sibling("Package.swift")
        case .cargoTarget: return sibling("Cargo.toml") || sibling("pom.xml") || inside("CACHEDIR.TAG")
        case .derivedData: return isGit || inside("Build") || inside("ModuleCache.noindex") || inside("Index.noindex")
        case .dist: return isGit && (sibling("package.json") || sibling("pyproject.toml") || sibling("setup.py"))
        case .nextBuild: return sibling("package.json")
        case .virtualEnvironment: return inside("pyvenv.cfg")
        }
    }
}
