import Foundation

/// Disk use of agents Domovy only measures (docs/research/agent_storage_formats.md, Q9; none was
/// installed on the development Mac, so every path comes from docs or third-party readers). Each
/// is measuring only, with the reason on its rows; Domovy offers nothing that changes them.
public struct MeasuredAgentFootprint: FootprintProvider {
    public let kind: AgentKind
    let home: URL

    struct Row {
        let name: String
        let path: String
        let disposition: Footprint.Disposition
        let note: String
    }

    public init(kind: AgentKind, home: URL) {
        self.kind = kind
        self.home = home.standardizedFileURL
    }

    /// Every measured-only agent.
    public static func all(home: URL) -> [MeasuredAgentFootprint] {
        AgentKind.allCases.filter { $0.isFootprintOnly && $0 != .herdr }.map { MeasuredAgentFootprint(kind: $0, home: home) }
    }

    /// The first row's folder is where Domovy looks for the agent.
    var rows: [Row] {
        switch kind {
        case .windsurf:
            // https://docs.windsurf.com/windsurf/cascade/memories; cascade/*.pb reported encrypted per conversation [3P].
            [Row(name: "Cascade conversations", path: ".codeium/windsurf/cascade", disposition: .consequences,
                 note: "Windsurf encrypts each conversation, so Domovy cannot tell them apart. Delete conversations in Windsurf."),
             Row(name: "Memories and rules", path: ".codeium/windsurf/memories", disposition: .keep,
                 note: "Cascade's memories and your global_rules.md. Domovy never removes them."),
             Row(name: "Other", path: ".codeium/windsurf", disposition: .keep, note: "Windsurf's state, caches and settings. Left alone."),
             Row(name: "Editor", path: "Library/Application Support/Windsurf", disposition: .keep, note: "Windsurf's editor state and extensions. Left alone.")]
        case .trae:
            // ModularData/ai-agent/database.db is SQLCipher-style encrypted [3P, xitula/trae-session-export].
            [Row(name: "Agent chats", path: "Library/Application Support/Trae/ModularData/ai-agent", disposition: .consequences,
                 note: "Trae keeps its chats in an encrypted database, so Domovy only measures it. Delete chats in Trae."),
             Row(name: "Agent chats (Trae CN)", path: "Library/Application Support/Trae CN/ModularData/ai-agent", disposition: .consequences,
                 note: "Trae keeps its chats in an encrypted database, so Domovy only measures it. Delete chats in Trae."),
             Row(name: "Editor", path: "Library/Application Support/Trae", disposition: .keep, note: "Trae's editor state and extensions. Left alone."),
             Row(name: "Editor (Trae CN)", path: "Library/Application Support/Trae CN", disposition: .keep, note: "Trae's editor state and extensions. Left alone.")]
        case .warp:
            // https://docs.warp.dev/agents/cli/agent-conversations.md; warp.sqlite tables agent_conversations, ai_queries [3P].
            [Row(name: "App database (conversations)", path: "Library/Group Containers/2BBY89MBSN.dev.warp/Library/Application Support/dev.warp.Warp-Stable",
                 disposition: .keep,
                 note: "Warp keeps agent conversations in its main database, which it uses all the time and syncs to its cloud. Domovy never changes it; delete conversations in Warp.")]
        case .amp:
            // https://ampcode.com/docs/threads: threads live on Amp's servers (`amp threads list|archive|delete`).
            [Row(name: "Thread cache", path: ".local/share/amp", disposition: .keep,
                 note: "Amp keeps threads on its servers; these are local copies. Domovy offers nothing destructive here; use amp threads archive or delete."),
             Row(name: "Settings and sign-in", path: ".config/amp", disposition: .keep, note: "Amp's settings and secrets. Domovy never removes them.")]
        case .junie:
            // https://junie.jetbrains.com/docs/junie-cli.html: settings.json, trust/; the session folder is undocumented.
            [Row(name: "Junie CLI", path: ".junie", disposition: .keep,
                 note: "Junie's session folder is not documented, so Domovy only measures it. Junie keeps full context for its last 10 sessions itself.")]
        case .iflow:
            // iflow-ai/iflow-cli@4642808a README#L1-L2: the service shut down on 2026-04-17.
            [Row(name: "Chats and checkpoints", path: ".iflow/tmp", disposition: .consequences,
                 note: "iFlow CLI shut down in April 2026. Its chats here are no longer used; remove ~/.iflow in Finder if you do not need them."),
             Row(name: "Snapshots", path: ".iflow/snapshots", disposition: .consequences, note: "Snapshots of the discontinued iFlow CLI."),
             Row(name: "Caches", path: ".iflow/cache", disposition: .safe, note: "Checkpoint caches of the discontinued iFlow CLI."),
             Row(name: "Settings", path: ".iflow", disposition: .keep, note: "iFlow's settings and sign-in. Left alone.")]
        default:
            []
        }
    }

    public func footprint() async throws -> Footprint {
        let rows = rows
        let folders = rows.map { home.appendingPathComponent($0.path, isDirectory: true) }
        // Folders macOS keeps private without Full Disk Access (Warp's group container) get a
        // row that says so instead of vanishing or reading as empty.
        let blocked = Set(folders.filter(FullDiskAccess.isBlocked))
        guard let root = folders.first(where: { FileSystem.isDirectory($0) || blocked.contains($0) }) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        var unmeasured: [Footprint.Category] = []
        for (row, folder) in zip(rows, folders) where blocked.contains(folder) {
            unmeasured.append(Footprint.Category(name: row.name, url: folder, sizeBytes: 0, disposition: .keep, note: FullDiskAccess.blockedNote))
        }
        for (row, folder) in zip(rows, folders) where FileSystem.isDirectory(folder) && !blocked.contains(folder) {
            // A folder that holds an earlier row counts only what is left beside it.
            let inner = folders.filter { $0 != folder && FileSystem.relativePath(of: $0, under: folder) != nil }
            if inner.isEmpty, !builder.isClaimed(folder) {
                builder.add(row.name, folder, row.disposition, row.note)
            } else {
                builder.add(row.name, leftovers(of: folder, around: inner, builder: builder), reveal: folder, row.disposition, row.note)
            }
        }
        let measured = builder.build()
        return unmeasured.isEmpty ? measured : Footprint(agent: kind, root: root, categories: measured.categories + unmeasured)
    }

    /// The children of `folder`, descending into those that contain one of `inner`.
    private func leftovers(of folder: URL, around inner: [URL], builder: FootprintBuilder) -> [URL] {
        FileSystem.children(of: folder).flatMap { child -> [URL] in
            if builder.isClaimed(child) || inner.contains(child.standardizedFileURL) { return [] }
            if inner.contains(where: { FileSystem.relativePath(of: $0, under: child) != nil }) {
                return leftovers(of: child, around: inner, builder: builder)
            }
            return [child]
        }
    }
}
