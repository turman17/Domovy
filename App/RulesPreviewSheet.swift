import DomovyCore
import SwiftUI

/// What rules would do right now: every session by rule with its size and action, and every
/// session left alone with the reason. Run Now executes exactly these sessions, planned again
/// with fresh live checks; a preview from the editor only shows.
struct RulesPreviewSheet: View {
    let request: RuleReviewRequest

    @Environment(RulesController.self) private var controller
    @Environment(\.dismiss) private var dismiss
    /// Nil while planning.
    @State private var preview: RulePreview?

    private var title: String {
        if request.isPreviewOnly { return "What this rule would do now" }
        return request.rules.count == 1 ? "Run \u{201C}\(request.rules[0].title)\u{201D}?" : "Run \(request.rules.count) rules now?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let preview {
                Text(preview.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !preview.matches.isEmpty || !preview.skipped.isEmpty {
                    list(preview)
                }
                ForEach(preview.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    Text("Checking sessions\u{2026}").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            }
            HStack {
                Spacer()
                if request.isPreviewOnly {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Run Now") {
                        guard let preview else { return }
                        Task {
                            await controller.run(request.rules, reviewed: preview)
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(preview?.isEmpty != false || controller.isRunning)
                    .help(controller.isRunning ? "Rules are already running" : preview == nil ? "Still checking sessions" : preview?.isEmpty == true ? "Nothing matches right now" : "Runs exactly these sessions. You can undo this.")
                }
            }
        }
        .padding(20)
        .frame(width: 600)
        .task {
            guard preview == nil else { return }
            if let given = request.preview {
                preview = given
            } else {
                preview = await controller.preview(request.rules)
            }
        }
    }

    private func list(_ preview: RulePreview) -> some View {
        List {
            ForEach(request.rules) { rule in
                let matches = preview.matches(for: rule.id)
                if !matches.isEmpty {
                    Section(rule.title) {
                        ForEach(matches) { match in
                            MatchRow(match: match)
                        }
                    }
                }
            }
            if !preview.skipped.isEmpty {
                Section("Left alone") {
                    ForEach(Array(preview.skipped.enumerated()), id: \.offset) { _, skip in
                        HStack(alignment: .top, spacing: 8) {
                            AgentGlyph(agent: skip.agent)
                            Text(skip.sessionID.map { String($0.prefix(8)) } ?? skip.agent.displayName)
                                .font(.system(.callout, design: .monospaced))
                            Text(skip.reason)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .frame(minHeight: 160, maxHeight: 320)
    }
}

private struct MatchRow: View {
    let match: RuleMatch

    private var action: String {
        switch match.plan.destination {
        case .trash: "To the Trash"
        case .quarantine: "To quarantine"
        case nil: "Archive"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            AgentGlyph(agent: match.session.agent)
            VStack(alignment: .leading, spacing: 1) {
                Text(match.session.displayTitle)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(match.session.projectName ?? "No project")
                    Text("\u{00B7}")
                    Text("last active")
                    RelativeDateText(date: match.session.lastActive)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text(action)
                .font(.caption)
                .foregroundStyle(.secondary)
            SizeText(bytes: match.plan.totalBytes)
                .font(.system(.callout, design: .monospaced))
                .frame(minWidth: 64, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}
