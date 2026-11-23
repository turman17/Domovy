import AppKit
import DomovyCore
import SwiftUI

/// Get Info (⌘I), like the Finder's: every fact Domovy knows about a session and every file
/// and index entry that belongs to it.
struct SessionInfoSheet: View {
    let session: Session

    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var artifacts: [Artifact]?
    @State private var loadError: String?

    private var findings: [SecretFinding] { library.findings(for: session) }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    general
                    files
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Show in Finder", systemImage: "folder") { revealInFinder(session) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 560, height: 600)
        .task(id: session.id) {
            do {
                artifacts = try await library.artifacts(of: session)
            } catch {
                loadError = error.localizedDescription
                artifacts = []
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentGlyph(agent: session.agent)
                .scaleEffect(2)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.displayTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text("\(session.agentLabel) · \(session.sizeBytes.formatted(.byteCount(style: .file)))")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusLabel(session: session)
        }
    }

    private var general: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            InfoRow(label: "Agent", value: session.agent.displayName)
            InfoRow(label: "Session ID", value: session.id, monospaced: true)
            if let project = session.projectPath {
                InfoRow(label: "Project", value: (project as NSString).abbreviatingWithTildeInPath, monospaced: true)
            }
            InfoRow(label: "Transcript", value: (session.transcriptURL.path as NSString).abbreviatingWithTildeInPath, monospaced: true)
            InfoRow(
                label: "Last active",
                value: "\(session.lastActive.formatted(date: .long, time: .shortened)) (\(session.lastActive.formatted(.relative(presentation: .named))))"
            )
            InfoRow(label: "Size", value: "\(session.sizeBytes.formatted(.byteCount(style: .file))) (\(session.sizeBytes.formatted()) bytes)")
            if let expiresAt = session.expiresAt {
                InfoRow(label: "Swept by agent", value: expiresAt.formatted(date: .long, time: .omitted))
            }
            if let note = session.retentionNote {
                InfoRow(label: "Retention", value: note)
            }
            InfoRow(label: "Compressed", value: session.isArchived ? "Yes, archived by Domovy or the agent" : "No")
            if let desktop = session.desktop {
                InfoRow(label: "Claude Desktop", value: desktop.isArchived ? "Listed, archived there" : "Listed in its sessions")
            }
            if session.memberCount > 1 {
                InfoRow(label: "Chats", value: "\(session.memberCount) chats shown as one row")
            }
            if !findings.isEmpty {
                InfoRow(label: "Secret scan", value: "\(findings.count) possible \(findings.count == 1 ? "secret" : "secrets")")
            }
            if let command = resumeCommand(for: session) {
                InfoRow(label: "Resume", value: command, monospaced: true)
            }
        }
    }

    @ViewBuilder
    private var files: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What belongs to this session")
                .font(.headline)
            if let artifacts {
                if let loadError {
                    Text(loadError).foregroundStyle(.secondary)
                } else if artifacts.isEmpty {
                    Text("No files found.").foregroundStyle(.secondary)
                }
                ForEach(artifacts, id: \.self) { artifact in
                    ArtifactRow(artifact: artifact)
                    Divider()
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
        }
    }
}

private struct ArtifactRow: View {
    let artifact: Artifact

    private var symbol: String {
        switch artifact.kind {
        case .file: "doc"
        case .folder: "folder"
        case .indexEntry: "list.bullet.indent"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.note)
                Text((artifact.url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(artifact.url.path)
                    .textSelection(.enabled)
            }
            Spacer()
            if artifact.kind != .indexEntry {
                SizeText(bytes: artifact.sizeBytes)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Button("Show in Finder", systemImage: "arrow.right.circle") {
                NSWorkspace.shared.activateFileViewerSelecting([artifact.url])
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("Show in Finder")
        }
    }
}

/// The transcript in the Finder, or its folder when the file has moved.
@MainActor
func revealInFinder(_ session: Session) {
    let url = session.transcriptURL
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
        NSWorkspace.shared.open(url.deletingLastPathComponent())
    }
}

/// The shell command that reopens the session in its agent, when the agent has one.
func resumeCommand(for session: Session) -> String? {
    let cd = session.projectPath.map { "cd \(shellQuoted($0)) && " } ?? ""
    switch session.agent {
    case .claudeCode: return cd + "claude --resume \(session.id)"
    case .codex: return cd + "codex resume \(session.id)"
    default: return nil
    }
}

private func shellQuoted(_ text: String) -> String {
    "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

@MainActor
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
