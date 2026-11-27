import DomovyCore
import SwiftUI

/// Right-hand pane: who, where, how big, then the conversation.
struct SessionInspector: View {
    let session: Session
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onRedact: () -> Void

    @Environment(SessionLibrary.self) private var library
    @State private var loadedArtifacts: (sessionID: Session.ID, artifacts: [Artifact])?
    @State private var pace = LoadPace()

    /// Artifacts of this session; empty until they are read.
    private var artifacts: [Artifact] {
        loadedArtifacts?.sessionID == session.id ? loadedArtifacts?.artifacts ?? [] : []
    }

    private var isLive: Bool { session.status == .live }
    private var findings: [SecretFinding] { library.findings(for: session) }

    private var archivedHelp: String {
        switch session.agent {
        case .codex: "Already archived in Codex."
        case .openCode: "Archived in OpenCode."
        default: "Already archived: its files are compressed on disk."
        }
    }

    private var archiveHelp: String {
        switch session.agent {
        case .codex: "Archive this session in Codex (codex archive), or compress it on disk without the CLI. You can undo this."
        case .openCode: "OpenCode keeps sessions inside its database, so there is no file to compress."
        case .cursor where CursorAdapter.isEditorChat(session): "Cursor keeps this chat as rows inside its database, so there is no file to compress."
        default: "Compress this session on disk. \(session.agent.displayName) can still resume it. You can undo this."
        }
    }

    private var footprintLine: String {
        let files = artifacts.filter { $0.kind != .indexEntry }.count
        let entries = artifacts.filter { $0.kind == .indexEntry }.count
        var text = session.sizeBytes.formatted(.byteCount(style: .file))
        // Counts only once they are read for this session, never the previous row's.
        if loadedArtifacts?.sessionID == session.id {
            text += " in \(files) \(files == 1 ? "file or folder" : "files and folders")"
        }
        if entries > 0 { text += ", \(entries) index \(entries == 1 ? "entry" : "entries")" }
        if session.isArchived { text += " · archived" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
            if !findings.isEmpty {
                SecretsSection(session: session, findings: findings, onRedact: onRedact)
                    .padding(16)
                Divider()
            }
            if session.memberCount > 1 {
                GroupMembersView(session: session, artifacts: artifacts)
            } else {
                TranscriptView(session: session)
            }
            Divider()
            footer
                .padding(16)
        }
        .task(id: session.id) {
            // Wait for the selection to rest (arrow key held down); adapter reads cannot be
            // cancelled, so a result for a row no longer selected is dropped.
            guard await pace.wait() else { return }
            let session = self.session
            let artifacts = (try? await library.artifacts(of: session)) ?? []
            guard !Task.isCancelled else { return }
            loadedArtifacts = (session.id, artifacts)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.displayTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                AgentGlyph(agent: session.agent)
                Text(session.agent.displayName)
                if let project = session.projectName {
                    Text("·").foregroundStyle(.tertiary)
                    Text(project).help(session.projectPath ?? project)
                }
                Text("·").foregroundStyle(.tertiary)
                RelativeDateText(date: session.lastActive)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Text(footprintLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help("\(session.sizeBytes.formatted()) bytes")
            if let usage = library.tokenUsage[session.id]?.usage {
                Text("\(TokenCounts.compact(usage.totals.total)) tokens" + (usage.cost.map { " \u{00B7} \($0.text)" + ($0.source == .agent ? "" : " est.") } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(usage.breakdown)
            }
            if let desktop = session.desktop {
                Label(desktop.isArchived ? "In Claude Desktop, archived there" : "In Claude Desktop's session list", systemImage: "macwindow")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Deleting this session also takes it off Claude Desktop's list. Claude Desktop must be quit for that.")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            let readOnly = library.readOnlyNote(for: session)
            HStack(spacing: 8) {
                Button("Archive…", systemImage: "archivebox", action: onArchive)
                    .disabled(!library.canArchive(session))
                    .help(readOnly ?? (session.isArchived ? archivedHelp : isLive ? "This session is live, so it cannot be archived." : archiveHelp))
                Button("Delete…", systemImage: "trash", action: onDelete)
                    .disabled(!library.canDelete(session))
                    .help(readOnly ?? (isLive ? "This session is live, so it cannot be deleted." : "Remove every file and index entry of this session. Shows the plan first. You can undo this."))
                Spacer()
                ResumeButtons(session: session)
            }
            .tourAnchor(.sessionActions)
            if let readOnly {
                Label(readOnly, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let placement = library.herdrPlacement(of: session) {
                Label("\(placement.liveReason) Quit the agent there before deleting.", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if isLive {
                Label("Live. Quit the \(session.agent.displayName) session using it before deleting.", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Space to preview · ⌥⌘A to archive · ⌘⌫ to delete · ⌘Z to undo")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The chats a grouped row stands for (Gemini CLI's a2a server writes hundreds of empty ones),
/// in place of a transcript. Collapsed by default.
struct GroupMembersView: View {
    let session: Session
    let artifacts: [Artifact]
    @State private var isExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(session.memberCount) chats without messages share one session id. Domovy shows them as one row and deletes them together.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                DisclosureGroup("Chat files (\(artifacts.count))", isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(artifacts, id: \.url) { artifact in
                            HStack {
                                Text(artifact.url.lastPathComponent)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .help(artifact.url.path)
                                Spacer()
                                SizeText(bytes: artifact.sizeBytes)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
