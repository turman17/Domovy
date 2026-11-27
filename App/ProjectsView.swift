import DomovyCore
import SwiftUI

/// How the Sessions screen lists sessions.
typealias SessionsLayout = DomovySettings.SessionsLayout

extension DomovySettings.SessionsLayout: @retroactive Identifiable {
    public var id: Self { self }
}

/// One row of the projects outline: a project with its sessions as children, or one session.
struct ProjectTableRow: Identifiable, Hashable {
    let id: String
    let name: String
    let help: String
    let agents: [AgentKind]
    let sessionCount: Int
    let sizeBytes: Int64
    let tokens: Int64
    let tokensText: String
    let tokensHelp: String
    let lastActive: Date
    let session: Session?
    let group: ProjectGroup?
    var children: [ProjectTableRow]?

    var sortName: String { name }

    static func project(_ group: ProjectGroup, rows: [Session.ID: SessionRow]) -> ProjectTableRow {
        let usage = group.sessions.compactMap { rows[$0.id]?.usage }.reduce(TokenUsage(), +)
        let counted = group.sessions.filter { rows[$0.id]?.usage != nil }.count
        let n = group.sessions.count
        var tokensHelp = counted == 0 ? "None of these sessions records token usage." : usage.breakdown
        if counted > 0, counted < n { tokensHelp += "\n\(counted) of \(n) sessions record tokens." }
        return ProjectTableRow(
            id: "p:" + group.id, name: group.name, help: group.path ?? "Sessions whose agent recorded no project folder.",
            agents: group.agents, sessionCount: n, sizeBytes: group.sizeBytes,
            tokens: counted == 0 ? -1 : usage.totals.total,
            tokensText: counted == 0 ? "\u{2014}" : TokenCounts.compact(usage.totals.total), tokensHelp: tokensHelp,
            lastActive: group.lastActive, session: nil, group: group,
            children: group.sessions.compactMap { rows[$0.id].map(ProjectTableRow.session) }
        )
    }

    static func session(_ row: SessionRow) -> ProjectTableRow {
        ProjectTableRow(id: "s:" + row.id, name: row.title, help: row.agentHelp, agents: [row.session.agent], sessionCount: 1,
                        sizeBytes: row.sizeBytes, tokens: row.tokenSortKey, tokensText: row.tokensText, tokensHelp: row.tokensHelp,
                        lastActive: row.lastActive, session: row.session, group: nil, children: nil)
    }
}

/// Sessions grouped by project folder across every agent, as an outline: totals per project
/// and "Clean Up This Project", which opens the usual archive or delete plan for its sessions.
struct ProjectsView: View {
    /// The filtered session rows.
    let rows: [SessionRow]
    let onSelectSessions: (Set<Session.ID>) -> Void
    let onOpen: (Session) -> Void
    let onArchive: ([Session]) -> Void
    let onDelete: ([Session]) -> Void
    let onExport: ([Session]) -> Void
    let onShowInList: (ProjectGroup) -> Void

    @Environment(SessionLibrary.self) private var library
    @State private var selection: Set<ProjectTableRow.ID> = []
    @State private var sortOrder = [KeyPathComparator(\ProjectTableRow.lastActive, order: .reverse)]
    @State private var projects: [ProjectTableRow] = []

    private var selectedProject: ProjectTableRow? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return projects.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(of: ProjectTableRow.self, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Project", value: \.sortName) { row in
                    HStack(spacing: 6) {
                        if row.session == nil {
                            Image(systemName: row.group?.path == nil ? "questionmark.folder" : "folder")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                        }
                        Text(row.name).lineLimit(1)
                    }
                    .help(row.help)
                }
                .width(min: 180, ideal: 300)
                TableColumn("Agents") { row in
                    HStack(spacing: 4) {
                        ForEach(row.agents.prefix(5), id: \.self) { AgentGlyph(agent: $0) }
                        if row.session != nil, let agent = row.agents.first {
                            Text(agent.displayName).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .help(row.agents.map(\.displayName).joined(separator: ", "))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(row.agents.map(\.displayName).joined(separator: ", "))
                }
                .width(min: 80, ideal: 120)
                TableColumn("Sessions", value: \.sessionCount) { row in
                    Text(row.session == nil ? "\(row.sessionCount)" : "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 64)
                TableColumn("Size", value: \.sizeBytes) { row in
                    Text(row.sizeBytes.formatted(.byteCount(style: .file)))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help("\(row.sizeBytes.formatted()) bytes")
                }
                .width(min: 60, ideal: 76)
                TableColumn("Tokens", value: \.tokens) { row in
                    Text(row.tokensText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(row.tokensHelp)
                }
                .width(min: 56, ideal: 64)
                TableColumn("Last active", value: \.lastActive) { row in
                    Text(row.lastActive.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                        .help(row.lastActive.formatted(date: .abbreviated, time: .shortened))
                }
                .width(min: 90, ideal: 110)
            } rows: {
                ForEach(projects) { project in
                    DisclosureTableRow(project) {
                        ForEach(project.children ?? []) { TableRow($0) }
                    }
                }
            }
            .contextMenu(forSelectionType: ProjectTableRow.ID.self) { ids in
                menu(for: ids)
            } primaryAction: { ids in
                if let session = sessions(in: ids).first, ids.count == 1, ids.first?.hasPrefix("s:") == true { onOpen(session) }
            }
            // Like the session list: Delete opens the delete plan, Space previews one session.
            .onDeleteCommand {
                let sessions = sessions(in: selection)
                if sessions.contains(where: library.canDelete) { onDelete(sessions) }
            }
            .onKeyPress(.space) {
                guard selection.count == 1, selection.first?.hasPrefix("s:") == true, let session = sessions(in: selection).first else { return .ignored }
                onOpen(session)
                return .handled
            }
            if let project = selectedProject, let group = project.group {
                Divider()
                ProjectFooter(project: project, group: group, onArchive: onArchive, onDelete: onDelete)
            }
        }
        .task(id: rows) { rebuild() }
        .onChange(of: sortOrder) { rebuild() }
        .onChange(of: selection) {
            onSelectSessions(Set(selection.filter { $0.hasPrefix("s:") }.map { String($0.dropFirst(2)) }))
        }
    }

    private func rebuild() {
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        projects = ProjectGroup.group(rows.map(\.session)).map { ProjectTableRow.project($0, rows: byID) }.sorted(using: sortOrder)
    }

    /// Every session the selection stands for: a project row brings all of its sessions.
    private func sessions(in ids: Set<ProjectTableRow.ID>) -> [Session] {
        var seen = Set<Session.ID>()
        var result: [Session] = []
        for project in projects {
            let members = ids.contains(project.id) ? project.group?.sessions ?? [] : (project.children ?? []).filter { ids.contains($0.id) }.compactMap(\.session)
            for session in members where seen.insert(session.id).inserted { result.append(session) }
        }
        return result
    }

    @ViewBuilder
    private func menu(for ids: Set<ProjectTableRow.ID>) -> some View {
        let sessions = sessions(in: ids)
        let n = sessions.count
        if ids.count == 1, let id = ids.first, let project = projects.first(where: { $0.id == id }), let group = project.group {
            Button("Show in Session List", systemImage: "list.bullet") { onShowInList(group) }
                .disabled(group.path == nil)
                .help(group.path == nil ? "These sessions have no project folder" : "")
            if let path = group.path, FileManager.default.fileExists(atPath: path) {
                Button("Open Project Folder", systemImage: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
            }
            Divider()
        } else if n == 1, let session = sessions.first {
            Button("Quick Look", systemImage: "eye") { onOpen(session) }
            ResumeButtons(session: session)
            Divider()
        }
        if n > 0 {
            Button(n == 1 ? "Export Transcript\u{2026}" : "Export \(n) Transcripts\u{2026}", systemImage: "square.and.arrow.up") { onExport(sessions) }
            Divider()
            Button(n == 1 ? "Archive\u{2026}" : "Archive \(n) Sessions\u{2026}", systemImage: "archivebox") { onArchive(sessions) }
                .disabled(!sessions.contains(where: library.canArchive))
                .help(sessions.contains(where: library.canArchive) ? "" : "Nothing here can be archived: live, already archived or read-only.")
            Button(n == 1 ? "Move to Trash\u{2026}" : "Move \(n) Sessions to Trash\u{2026}", systemImage: "trash") { onDelete(sessions) }
                .disabled(!sessions.contains(where: library.canDelete))
                .help(sessions.contains(where: library.canDelete) ? "" : "Nothing here can be moved: live, busy or read-only.")
        }
    }
}

/// The selected project's totals and its cleanup actions.
private struct ProjectFooter: View {
    let project: ProjectTableRow
    let group: ProjectGroup
    let onArchive: ([Session]) -> Void
    let onDelete: ([Session]) -> Void

    @Environment(SessionLibrary.self) private var library

    var body: some View {
        let n = group.sessions.count
        HStack(spacing: 8) {
            Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline)
                Text("\(n) \(n == 1 ? "session" : "sessions") from \(group.agents.count) \(group.agents.count == 1 ? "agent" : "agents") \u{00B7} \(group.sizeBytes.formatted(.byteCount(style: .file)))" + (project.tokens >= 0 ? " \u{00B7} \(project.tokensText) tokens" : ""))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Clean Up This Project\u{2026}") {
                Button("Archive \(n == 1 ? "Its Session" : "Its \(n) Sessions")\u{2026}") { onArchive(group.sessions) }
                    .disabled(!group.sessions.contains(where: library.canArchive))
                    .help(group.sessions.contains(where: library.canArchive) ? "" : "None of its sessions can be archived: they are live, already archived or read-only.")
                Button("Move \(n == 1 ? "Its Session" : "Its \(n) Sessions") to Trash\u{2026}") { onDelete(group.sessions) }
                    .disabled(!group.sessions.contains(where: library.canDelete))
                    .help(group.sessions.contains(where: library.canDelete) ? "" : "None of its sessions can be moved: they are live, busy or read-only.")
            }
            .fixedSize()
            .help("Shows the plan first: what moves or is compressed, and what is left alone. You can undo it.")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
