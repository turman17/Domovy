import Foundation

/// Herdr's own disk use (docs/research/agent_storage_formats.md, Herdr; verified on 0.9.5):
/// logs, layout snapshots and old binaries next to the state it needs. Measuring only; the
/// agents' worktrees Herdr made are in the leftovers section.
public struct HerdrFootprint: FootprintProvider {
    public let kind = AgentKind.herdr
    let home: URL

    public init(home: URL) {
        self.home = home.standardizedFileURL
    }

    var folder: URL { home.appendingPathComponent(".config/herdr", isDirectory: true) }
    var appFolder: URL { home.appendingPathComponent(".config/herdr-app", isDirectory: true) }

    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(folder) || FileSystem.isDirectory(appFolder) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: FileSystem.isDirectory(folder) ? folder : appFolder)
        // `herdr.log`, `herdr-client.log`, `herdr-server.log`, and each named session's under `sessions/<name>/`.
        let sessionLogs = FileSystem.children(of: folder.appendingPathComponent("sessions")).flatMap { FileSystem.children(of: $0) }
        let logs = (FileSystem.children(of: folder) + sessionLogs).filter { $0.pathExtension == "log" }
        builder.add("Logs", logs, reveal: folder, .safe,
                    "Herdr's logs. Safe to remove; Herdr starts new ones. It keeps them open while it runs.")
        builder.add("Layout snapshots", [folder.appendingPathComponent("session-snapshots"), folder.appendingPathComponent("session-backups")],
                    reveal: folder, .consequences,
                    "Up to 48 earlier layouts Herdr can restore, and copies of unreadable session files. Removing them loses those restore points; the current layout stays.")
        let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
        let oldBinaries = FileSystem.children(of: bin).filter { $0.lastPathComponent.hasPrefix("herdr") && $0.pathExtension == "old" }
        builder.add("Old binaries", oldBinaries, reveal: bin, .safe, "Herdr binaries an update replaced. Nothing runs them.")
        let state = FileSystem.children(of: folder).filter { !builder.isClaimed($0) }
        builder.add("Layout and settings", state, reveal: folder, .keep,
                    "Herdr's current layout, the agent session ids it resumes, config.toml and its sockets. Domovy never removes them.")
        builder.add("Herdr app", appFolder, .keep, "The Herdr app's mods, themes and window state. Left alone.")
        return builder.build()
    }
}

/// Where `herdr worktree create` puts checkouts: `[worktrees] directory` in Herdr's
/// `config.toml`, default `~/.herdr/worktrees`, laid out `<directory>/<repo>/<branch-slug>`.
public enum HerdrWorktrees {
    public static func folder(home: URL) -> URL {
        let config = home.appendingPathComponent(".config/herdr/config.toml")
        if let text = try? String(contentsOf: config, encoding: .utf8), let value = directory(inConfig: text) {
            if value.hasPrefix("~/") { return home.appendingPathComponent(String(value.dropFirst(2)), isDirectory: true) }
            if value.hasPrefix("/") { return URL(fileURLWithPath: value, isDirectory: true) }
        }
        return home.appendingPathComponent(".herdr/worktrees", isDirectory: true)
    }

    /// `directory = "…"` in the `[worktrees]` table; a minimal reader for that one key.
    static func directory(inConfig text: String) -> String? {
        var inTable = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inTable = line == "[worktrees]"; continue }
            guard inTable, line.hasPrefix("directory") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "directory" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.first == "\"", let end = value.dropFirst().firstIndex(of: "\"") else { return nil }
            return String(value[value.index(after: value.startIndex)..<end])
        }
        return nil
    }
}
