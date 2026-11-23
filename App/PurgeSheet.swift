import DomovyCore
import SwiftUI

/// Purge originals: the one permanent delete in Domovy. Names every file, says plainly that it
/// cannot be undone, and keeps Return on Cancel so it never runs by accident.
struct PurgeSheet: View {
    let plan: PurgePlan

    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var isExecuting = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan.isEmpty ? "Nothing to purge" : "Permanently delete \(plan.items.count) \(plan.items.count == 1 ? "original" : "originals")?")
                .font(.title3.weight(.semibold))
            Text(plan.summary)
                .foregroundStyle(.secondary)
            if !plan.isEmpty {
                Label("These are the copies Domovy kept in its quarantine, with the secrets still in plain text. They do not go to the Trash.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                list
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            footer
        }
        .padding(20)
        .frame(width: 560)
    }

    private var list: some View {
        List(plan.items, id: \.file) { item in
            ChangeRow(
                symbol: item.reason == .redactedOriginal ? "doc.badge.ellipsis" : "folder",
                path: relativePath(item.originalPath, under: library.home),
                note: (item.reason == .redactedOriginal ? "Original of a redacted file" : "Deleted session flagged by the secret scan")
                    + " \u{00B7} quarantine/\(item.file.lastPathComponent)",
                size: item.sizeBytes.formatted(.byteCount(style: .file))
            )
        }
        .frame(height: 220)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !plan.isEmpty {
                SizeText(bytes: plan.totalBytes)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if plan.isEmpty {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete Permanently", role: .destructive, action: execute)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(isExecuting)
            }
        }
    }

    private func execute() {
        isExecuting = true
        Task {
            do {
                try await library.purge(plan)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isExecuting = false
            }
        }
    }
}
