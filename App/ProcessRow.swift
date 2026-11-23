import DomovyCore
import Foundation

/// One row of the Processes table: the orphans' header, an agent tree's root, or a process.
struct ProcessRow: Identifiable, Hashable {
    enum Content: Hashable {
        /// "Orphaned · agent is gone", with every orphan below it.
        case orphans(count: Int)
        case process(ProcessNode)
    }

    let id: String
    let content: Content
    /// Shown instead of the process name: "Codex · Add rate limiting".
    let title: String
    let children: [ProcessRow]?

    var node: ProcessNode? {
        if case .process(let node) = content { return node }
        return nil
    }

    /// Memory of the row and everything below it.
    var totalBytes: Int64 {
        switch content {
        case .orphans: (children ?? []).reduce(0) { $0 + $1.totalBytes }
        case .process(let node): node.totalBytes
        }
    }

    var cpuPercent: Double? {
        switch content {
        case .orphans:
            let values = (children ?? []).compactMap(\.cpuPercent)
            return values.isEmpty ? nil : values.reduce(0, +)
        case .process(let node):
            return node.totalCPUPercent
        }
    }

    /// Orphans on top, then one tree per agent, largest first. `search` keeps trees with a match.
    static func rows(_ report: ProcessReport, sessionTitle: (String) -> String?, search: String) -> [ProcessRow] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ node: ProcessNode, title: String) -> Bool {
            query.isEmpty || title.lowercased().contains(query) || node.subtree.contains { $0.name.lowercased().contains(query) || String($0.pid) == query }
        }
        func row(_ node: ProcessNode, title: String? = nil) -> ProcessRow {
            let kids = node.children.map { row($0) }
            return ProcessRow(id: "\(node.pid)-\(node.key.startMicros)", content: .process(node), title: title ?? node.name, children: kids.isEmpty ? nil : kids)
        }
        var rows: [ProcessRow] = []
        let orphans = report.orphans.filter { matches($0, title: $0.name) }
        if !orphans.isEmpty {
            rows.append(ProcessRow(id: "orphans", content: .orphans(count: orphans.count), title: "Orphaned · their agent is gone", children: orphans.map { row($0) }))
        }
        for group in report.groups {
            let title = groupTitle(group, sessionTitle: sessionTitle)
            if matches(group.root, title: title) { rows.append(row(group.root, title: title)) }
        }
        return rows
    }

    /// "Claude Code · Seed demo data", "Codex · 3 threads", or just the agent.
    static func groupTitle(_ group: ProcessGroup, sessionTitle: (String) -> String?) -> String {
        let ids = group.sessionIDs
        guard let first = ids.first else { return group.root.name }
        let name = sessionTitle(first) ?? "session \(first.prefix(8))"
        return ids.count == 1 ? "\(group.root.name) · \(name)" : "\(group.root.name) · \(name) +\(ids.count - 1)"
    }
}
