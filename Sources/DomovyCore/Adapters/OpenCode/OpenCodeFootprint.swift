import Foundation

extension OpenCodeAdapter {
    /// Read-only breakdown of OpenCode's data folder and settings. The database is split into
    /// its `event` log and the rest by page counts (`dbstat`), or by row bytes where that is not
    /// available; rows are counted, never read.
    public func footprint() async throws -> Footprint {
        guard FileSystem.isDirectory(root) else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)

        let protected = [layout.config] + ["auth.json", "mcp-auth.json", "bin"].map { root.appendingPathComponent($0) }
        builder.add("Settings and sign-in", protected, reveal: root, .keep, "OpenCode needs these to run. Domovy never removes them.")

        let database = layout.databaseFiles.filter { FileSystem.exists($0) }
        let usage = DiskUsage.measure(database)
        let share = eventShare()
        let events = DiskUsage(allocated: Int64(Double(usage.allocated) * share), logical: Int64(Double(usage.logical) * share))
        let rest = DiskUsage(allocated: usage.allocated - events.allocated, logical: usage.logical - events.logical)
        let count = OpenCodeIndex.load(layout).topLevel.count
        builder.add("Sessions (in opencode.db)", part: rest, of: database, reveal: root, .consequences,
                    "\(count) \(count == 1 ? "session" : "sessions"), plus OpenCode's projects and sign-ins in the same file. Delete sessions one by one in Sessions; OpenCode runs the delete.",
                    guidance: .manageInSessions)
        builder.add("Event log (in opencode.db)", part: events, of: database, reveal: root, .consequences,
                    "OpenCode's append-only log of session changes, \(Int((share * 100).rounded()))% of the database. It is how this file grows to gigabytes.",
                    guidance: .instructions(Self.eventLogAdvice))
        builder.claim(database)

        builder.add("File snapshots", layout.snapshots, .consequences,
                    "Git repositories behind OpenCode's undo of file edits. Set \"snapshot\": false in opencode.json to stop them.")
        builder.add("Older session files", layout.storage, .consequences,
                    "Sessions and diffs from OpenCode versions before its database. Newer versions may still read them.")
        builder.add("Logs", layout.logs, .safe, "Diagnostic logs. OpenCode writes new ones; remove them while it is quit.")
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }

    /// Shown with the event log row.
    static let eventLogAdvice = "OpenCode 1.18 has no command to compact its event log, and VACUUM alone frees nothing here (opencode#53760). Deleting old sessions in Sessions runs `opencode session delete`; Domovy reports whether their events went too. Domovy never edits the database itself."

    /// The `event` table's and its indexes' share of the database, 0 when there is none.
    func eventShare() -> Double {
        guard let reader = SQLiteReader(url: layout.database), reader.tables().contains("event") else { return 0 }
        let names = Set(reader.rows("SELECT name FROM sqlite_master WHERE tbl_name = 'event'").compactMap { $0.first ?? nil })
        let pages = reader.rows("SELECT name, sum(pgsize) FROM dbstat GROUP BY name")
        if !pages.isEmpty {
            let total = pages.reduce(0.0) { $0 + (Double($1.last.flatMap { $0 } ?? "") ?? 0) }
            let event = pages.filter { names.contains($0.first.flatMap { $0 } ?? "") }
                .reduce(0.0) { $0 + (Double($1.last.flatMap { $0 } ?? "") ?? 0) }
            return total > 0 ? min(1, event / total) : 0
        }
        // No dbstat in this SQLite: compare the event payloads with the file.
        let bytes = Double(reader.rows("SELECT coalesce(sum(length(data)), 0) FROM event").first?.first.flatMap { $0 } ?? "") ?? 0
        let file = Double(layout.databaseFiles.reduce(Int64(0)) { $0 + FileSystem.size(of: $1) })
        return file > 0 ? min(1, bytes / file) : 0
    }
}
