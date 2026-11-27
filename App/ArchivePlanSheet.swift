import DomovyCore
import SwiftUI

/// Sessions to archive. The sheet opens at once and plans them while it shows a spinner;
/// sessions with nothing to compress drop out there.
struct ArchiveRequest: Identifiable {
    let id = UUID()
    let sessions: [Session]
    /// Selected sessions left out, one line each ("2 live sessions are left alone.").
    var notes: [String] = []
}

/// Shows every file an archive compresses, sizes before and after, and the live check.
/// Return confirms, Escape cancels. The primary button uses the accent: nothing is removed.
struct ArchivePlanSheet: View {
    let request: ArchiveRequest

    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// Nil while planning.
    @State private var plans: [Plan]?
    @State private var failure: String?

    private var planned: [Plan] { plans ?? [] }
    private var files: [FileCompression] { planned.flatMap(\.compressions) }
    private var before: Int64 { files.reduce(0) { $0 + $1.sizeBytes } }
    private var after: Int64 { files.reduce(0) { $0 + $1.estimatedBytes } }
    private var isBatch: Bool { planned.count > 1 }
    private var commandCount: Int { planned.reduce(0) { $0 + $1.commands.count } }
    private var isBlocked: Bool { planned.contains { $0.liveCheck.isLive } }
    private var plannedSessions: [Session] {
        let ids = Set(planned.map(\.sessionID))
        return request.sessions.filter { ids.contains($0.id) }
    }
    private var expiringCount: Int { plannedSessions.filter { $0.status == .expiring }.count }

    /// Sessions the plans left out, said once the plans are in.
    private var notes: [String] {
        var notes = request.notes
        let dropped = request.sessions.count - plannedSessions.count
        if plans != nil, request.sessions.count > 1, dropped > 0, !planned.isEmpty {
            notes.append("\(dropped) \(dropped == 1 ? "session has" : "sessions have") nothing to compress or became live, and \(dropped == 1 ? "is" : "are") left alone.")
        }
        return notes
    }

    private var title: String {
        guard !isBatch, let session = plannedSessions.first ?? request.sessions.first else { return "Archive \(planned.count) sessions?" }
        return "Archive \u{201C}\(session.displayTitle)\u{201D}?"
    }

    private var summary: String {
        guard isBatch else { return planned.first?.summary ?? "Nothing to compress." }
        let n = files.count
        var parts: [String] = []
        if n > 0 {
            parts.append("Compresses \(n) \(n == 1 ? "file" : "files") (\(before.formatted(.byteCount(style: .file))) \u{2192} ~\(after.formatted(.byteCount(style: .file)))); the agents can still resume them.")
        }
        if commandCount > 0 {
            parts.append("Runs codex archive for \(commandCount) Codex \(commandCount == 1 ? "session" : "sessions"), then checks the result.")
        }
        let relocated = planned.filter { !$0.relocations.isEmpty }.count
        if relocated > 0 {
            parts.append("Moves \(relocated) \(relocated == 1 ? "session" : "sessions") into the agent's own archive folder, where it lists them as archived.")
        }
        return (parts + ["You can undo this."]).joined(separator: " ")
    }

    var body: some View {
        Group {
            if plans == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Checking \(request.sessions.count == 1 ? "the session" : "\(request.sessions.count) sessions")\u{2026}")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if planned.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nothing to archive")
                        .font(.title3.weight(.semibold))
                    Text(failure ?? nothingText)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if request.sessions.count == 1, let session = request.sessions.first {
                            Button("Show in Finder", systemImage: "folder") { revealInFinder(session) }
                        }
                        Spacer()
                        Button("OK") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                content
            }
        }
        .padding(20)
        .frame(width: 560)
        .task {
            do {
                let result = try await library.archivePlans(for: request.sessions)
                if result.count == 1, let plan = result.first, plan.isEmpty, !plan.liveCheck.isLive {
                    // Nothing to change: the plan's own words say why.
                    failure = ([plan.remarks.isEmpty ? plan.summary : plan.remarks.joined(separator: " ")] + request.notes).joined(separator: " ")
                    plans = []
                } else {
                    plans = result
                }
            } catch {
                failure = error.localizedDescription
                plans = []
            }
            #if DEBUG
            PerfDriver.shared.planShown = true
            #endif
        }
    }

    private var nothingText: String {
        let sessions = request.sessions
        let text = sessions.count == 1 && sessions[0].agent == .codex
            ? "This session is already in Codex's archive or has nothing to compress."
            : "\(sessions.count == 1 ? "This session's files are" : "These sessions' files are") already compressed or too small to gain from it."
        return ([text] + request.notes).joined(separator: " ")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(summary)
                .foregroundStyle(.secondary)
            ForEach(notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let plan = planned.first, !isBatch {
                LiveCheckRow(result: plan.liveCheck)
                RemarksView(remarks: plan.remarks.filter { $0 != summary })
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
    }

    private var changes: some View {
        List {
            ForEach(planned) { plan in
                CommandsSection(commands: plan.commands)
                if !plan.relocations.isEmpty {
                    Section("\(plan.agent.displayName) · moved to its archive folder") {
                        ForEach(plan.relocations, id: \.source) { item in
                            ChangeRow(
                                symbol: "archivebox",
                                path: relativePath(item.source, under: library.root(for: plan.agent)),
                                note: "\(item.note) \u{2192} \(item.target.deletingLastPathComponent().lastPathComponent)/",
                                size: item.sizeBytes.formatted(.byteCount(style: .file))
                            )
                        }
                    }
                }
                if !plan.compressions.isEmpty {
                    Section(sectionTitle(plan)) {
                        ForEach(plan.compressions, id: \.file) { item in
                            ChangeRow(
                                symbol: "doc.zipper",
                                path: relativePath(item.file, under: library.root(for: plan.agent)),
                                note: item.note,
                                size: "\(item.sizeBytes.formatted(.byteCount(style: .file))) \u{2192} ~\(item.estimatedBytes.formatted(.byteCount(style: .file)))"
                            )
                        }
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
            if !files.isEmpty {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("\(before.formatted(.byteCount(style: .file))) \u{2192} ~\(after.formatted(.byteCount(style: .file))) on disk")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("Estimate. \(before.formatted()) bytes on disk now.")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isBatch ? "Archive \(planned.count)" : "Archive", action: execute)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled((files.isEmpty && commandCount == 0) || isBlocked)
        }
    }

    /// Closes the sheet at once; the archive runs in the background and ends in a toast.
    private func execute() {
        let plans = planned
        let n = plans.count
        library.runInBackground(
            "Archiving \(n == 1 ? "1 session" : "\(n) sessions")\u{2026}",
            status: "Archiving\u{2026}",
            sessions: plans.map(\.sessionID)
        ) { [library] in
            try await library.archive(plans)
        }
        dismiss()
    }
}
