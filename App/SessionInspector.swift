import DomovyCore
import SwiftUI

/// Right-hand pane: who, where, how big, then the conversation.
struct SessionInspector: View {
    let session: Session
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onRedact: () -> Void

    @Environment(SessionLibrary.self) private var library
    @State private var artifacts: [Artifact] = []

    private var isLive: Bool { session.status == .live }
    private var findings: [SecretFinding] { library.findings(for: session) }

    private var archivedHelp: String {
        session.agent == .codex ? "Already archived in Codex." : "Already archived: its files are compressed on disk."
    }

    private var archiveHelp: String {
        session.agent == .codex
            ? "Archive this session in Codex (codex archive), or compress it on disk without the CLI. You can undo this."
            : "Compress this session on disk. Claude Code can still resume it. You can undo this."
    }

    private var footprintLine: String {
        let files = artifacts.filter { $0.kind != .indexEntry }.count
        let entries = artifacts.filter { $0.kind == .indexEntry }.count
        var text = "\(session.sizeBytes.formatted(.byteCount(style: .file))) in \(files) \(files == 1 ? "file or folder" : "files and folders")"
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
            TranscriptView(session: session)
            Divider()
            footer
                .padding(16)
        }
        .task(id: session.id) {
            artifacts = (try? await library.artifacts(of: session)) ?? []
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
            HStack(spacing: 8) {
                Button("Archive…", systemImage: "archivebox", action: onArchive)
                    .disabled(isLive || session.isArchived)
                    .help(session.isArchived ? archivedHelp : isLive ? "This session is live, so it cannot be archived." : archiveHelp)
                Button("Delete…", systemImage: "trash", action: onDelete)
                    .disabled(isLive)
                    .help(isLive ? "This session is live, so it cannot be deleted." : "Remove every file and index entry of this session. Shows the plan first. You can undo this.")
            }
            if isLive {
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
