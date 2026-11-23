import DomovyCore
import SwiftUI

/// Archive requests awaiting confirmation: one plan per session, sessions with nothing to
/// compress already left out.
struct ArchiveRequest: Identifiable {
    let id = UUID()
    let sessions: [Session]
    let plans: [Plan]
}

/// Shows every file an archive compresses, sizes before and after, and the live check.
/// Return confirms, Escape cancels. The primary button uses the accent: nothing is removed.
struct ArchivePlanSheet: View {
    let request: ArchiveRequest

    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var isExecuting = false
    @State private var failure: String?

    private var root: URL { library.adapter.root }
    private var files: [FileCompression] { request.plans.flatMap(\.compressions) }
    private var before: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    private var after: Int64 { files.reduce(0) { $0 + $1.estimatedBytes } }
    private var isBatch: Bool { request.plans.count > 1 }
    private var expiringCount: Int { request.sessions.filter { $0.status == .expiring }.count }

    private var title: String {
        guard !isBatch, let session = request.sessions.first else { return "Archive \(request.plans.count) sessions?" }
        return "Archive \u{201C}\(session.displayTitle)\u{201D}?"
    }

    private var summary: String {
        guard isBatch else { return request.plans.first?.summary ?? "Nothing to compress." }
        let n = files.count
        return "Compresses \(n) \(n == 1 ? "file" : "files") (\(before.formatted(.byteCount(style: .file))) \u{2192} ~\(after.formatted(.byteCount(style: .file)))) in \(request.plans.count) sessions. Claude Code can still resume them. You can undo this."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(summary)
                .foregroundStyle(.secondary)
            if let plan = request.plans.first, !isBatch {
                LiveCheckRow(result: plan.liveCheck)
            }
            if expiringCount > 0 {
                Label(
                    "Archiving keeps modification dates, so Claude Code still deletes \(expiringCount == 1 ? "this session" : "these sessions") on schedule. To keep them longer, raise cleanupPeriodDays.",
                    systemImage: "clock"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
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
            ForEach(request.plans) { plan in
                Section(sectionTitle(plan)) {
                    ForEach(plan.compressions, id: \.file) { item in
                        ChangeRow(
                            symbol: "doc.zipper",
                            path: relativePath(item.file, under: root),
                            note: item.note,
                            size: "\(item.sizeBytes.formatted(.byteCount(style: .file))) \u{2192} ~\(item.estimatedBytes.formatted(.byteCount(style: .file)))"
                        )
                    }
                }
            }
        }
        .frame(height: 300)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func sectionTitle(_ plan: Plan) -> String {
        let name = isBatch ? (request.sessions.first { $0.id == plan.sessionID }?.displayTitle ?? plan.sessionID) : plan.agent.displayName
        return "\(name) · compressed in place"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(before.formatted(.byteCount(style: .file))) \u{2192} ~\(after.formatted(.byteCount(style: .file))) on disk")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("Estimate. \(before.formatted()) bytes on disk now.")
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isBatch ? "Archive \(request.plans.count)" : "Archive", action: execute)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(files.isEmpty || isExecuting)
        }
    }

    private func execute() {
        isExecuting = true
        Task {
            do {
                try await library.archive(request.plans)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isExecuting = false
            }
        }
    }
}
