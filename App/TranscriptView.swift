import DomovyCore
import SwiftUI

/// The conversation as a clean chat: user prompts in tinted bubbles, assistant text plain,
/// tool calls as one-line chips. Reads a bounded prefix via the adapter; content is only shown.
struct TranscriptView: View {
    let session: Session

    @Environment(SessionLibrary.self) private var library
    @State private var transcript: Transcript?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let transcript {
                    ForEach(transcript.messages) { message in
                        MessageView(message: message)
                    }
                    if transcript.isTruncated {
                        Text("Showing the first \(transcript.messages.count) messages.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 8)
                    } else if transcript.messages.isEmpty {
                        Text("No readable messages in this transcript.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 24)
                    }
                } else if let failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(16)
        }
        .task(id: session.id) {
            transcript = nil
            failure = nil
            do {
                transcript = try await library.transcript(of: session)
            } catch {
                failure = error.localizedDescription
            }
        }
    }
}

private struct MessageView: View {
    let message: TranscriptMessage

    var body: some View {
        ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .text(let text):
                if message.role == .user {
                    Text(text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("You: \(text)")
                } else {
                    Text(text)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Assistant: \(text)")
                }
            case .toolCall(let summary):
                ToolCallChip(summary: summary)
            }
        }
    }
}

/// "Edit src/components/Hero.tsx": tool name in the UI font, its argument monospaced.
private struct ToolCallChip: View {
    let summary: String

    private var parts: (name: String, detail: String?) {
        guard let space = summary.firstIndex(of: " ") else { return (summary, nil) }
        return (String(summary[..<space]), String(summary[summary.index(after: space)...]))
    }

    private var symbol: String {
        switch parts.name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit": "doc"
        case "Read": "doc.text"
        case "Bash": "terminal"
        case "Grep", "Glob": "magnifyingglass"
        case "WebFetch", "WebSearch": "globe"
        case "Agent", "Task": "person.2"
        default: "wrench"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(parts.name)
                .foregroundStyle(.secondary)
            if let detail = parts.detail {
                Text(detail)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Tool call: \(summary)")
    }
}

/// Space bar quick look: the same chat, larger, closed with Space or Escape.
struct TranscriptPreviewSheet: View {
    let session: Session

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle).font(.headline).lineLimit(1)
                    Text("\(session.agent.displayName) · \(session.projectName ?? "no project")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            TranscriptView(session: session)
        }
        .frame(width: 640, height: 540)
        .onKeyPress(.space) {
            dismiss()
            return .handled
        }
    }
}
