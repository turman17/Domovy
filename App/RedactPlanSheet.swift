import DomovyCore
import SwiftUI

/// A redaction awaiting confirmation.
struct RedactRequest: Identifiable {
    let session: Session
    let plan: Plan
    var id: String { session.id }
}

/// Every value that will be replaced, what stays and why, and where the original goes.
/// Return confirms, Escape cancels. Accent, not red: undo puts the original back.
struct RedactPlanSheet: View {
    let request: RedactRequest

    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var isExecuting = false
    @State private var failure: String?

    private var plan: Plan { request.plan }
    private var root: URL { library.root(for: plan.agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Redact secrets in \u{201C}\(request.session.displayTitle)\u{201D}?")
                .font(.title3.weight(.semibold))
            Text(plan.summary)
                .foregroundStyle(.secondary)
            LiveCheckRow(result: plan.liveCheck)
            RemarksView(remarks: plan.remarks)
            changes
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            footer
        }
        .padding(20)
        .frame(width: 560)
    }

    private var changes: some View {
        List {
            ForEach(plan.redactions, id: \.file) { item in
                Section("\(relativePath(item.file, under: root)) \u{00B7} rewritten in place, original to quarantine") {
                    ForEach(item.lines, id: \.offset) { edit in
                        ForEach(edit.replacements, id: \.range.lowerBound) { replacement in
                            ChangeRow(
                                symbol: "key",
                                path: "line \(edit.line) \u{00B7} \(SecretRule.displayName(for: replacement.ruleID))",
                                note: "\(replacement.preview) \u{2192} [REDACTED:\(replacement.ruleID)]",
                                size: ""
                            )
                        }
                    }
                }
            }
            if !plan.skippedSecrets.isEmpty {
                Section("Left as they are") {
                    ForEach(plan.skippedSecrets, id: \.self) { item in
                        ChangeRow(
                            symbol: "minus.circle",
                            path: "\(item.file.lastPathComponent) \u{00B7} line \(item.line) \u{00B7} \(item.preview)",
                            note: item.reason,
                            size: ""
                        )
                    }
                }
            }
        }
        .frame(height: 280)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Modification dates and permissions stay as they are.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Redact", action: execute)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(plan.liveCheck.isLive || plan.isEmpty || isExecuting)
        }
    }

    private func execute() {
        isExecuting = true
        Task {
            do {
                try await library.redact(plan, for: request.session)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isExecuting = false
            }
        }
    }
}
