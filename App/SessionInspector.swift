import DomovyCore
import SwiftUI

/// Right-hand pane: who, where, how big, then the conversation.
struct SessionInspector: View {
    let session: Session
    let onDelete: () -> Void

    @Environment(SessionLibrary.self) private var library
    @State private var artifacts: [Artifact] = []

    private var isLive: Bool { session.status == .live }

    private var footprintLine: String {
        let files = artifacts.filter { $0.kind != .indexEntry }.count
        let entries = artifacts.filter { $0.kind == .indexEntry }.count
        var text = "\(session.sizeBytes.formatted(.byteCount(style: .file))) in \(files) \(files == 1 ? "file or folder" : "files and folders")"
        if entries > 0 { text += ", \(entries) index \(entries == 1 ? "entry" : "entries")" }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            Divider()
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
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Archive", systemImage: "archivebox") {}
                    .disabled(true)
                    .help("Archiving is not available yet.")
                Button("Delete…", systemImage: "trash", action: onDelete)
                    .disabled(isLive)
                    .help(isLive ? "This session is live, so it cannot be deleted." : "Move every file of this session to the Trash. You can undo this.")
            }
            if isLive {
                Label("Live. Quit the Claude Code session using it before deleting.", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Space to preview · ⌫ to delete · ⌘Z to undo")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
