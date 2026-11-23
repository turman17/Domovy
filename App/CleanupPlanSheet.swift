import DomovyCore
import SwiftUI

/// A guided Disk cleanup awaiting confirmation.
struct CleanupRequest: Identifiable {
    let id = UUID()
    let cleanup: CleanupPlan
}

/// One sheet for every guided cleanup: the size, what happens, the app-running and open-file
/// checks, every item that moves or is compressed, and what stays with the reason.
/// The button is the accent for safe cleanups and red only for rows with consequences.
struct CleanupPlanSheet: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var cleanup: CleanupPlan
    @State private var destination: Destination
    @State private var isExecuting = false
    @State private var failure: String?
    @State private var purgeNow = false

    init(request: CleanupRequest) {
        _cleanup = State(initialValue: request.cleanup)
        _destination = State(initialValue: request.cleanup.plan.destination ?? .trash)
    }

    private var plan: Plan { cleanup.plan }
    private var compresses: Bool { cleanup.cleanup.compresses }

    private var sizeText: String {
        let before = plan.totalBytes.formatted(.byteCount(style: .file))
        return compresses ? "\(before) \u{2192} ~\(plan.estimatedBytesAfter.formatted(.byteCount(style: .file)))" : before
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(cleanup.cleanup.title)
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(sizeText)
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                    .help("\(plan.totalBytes.formatted()) bytes on disk")
                Text(compresses ? "on disk now, and an estimate after" : "on disk now")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Text(cleanup.summary)
                .foregroundStyle(.secondary)
            LiveCheckRow(result: plan.liveCheck)
            RemarksView(remarks: plan.remarks)
            changes
            if plan.keepsToolCopies { FreeSpaceNowToggle(isOn: $purgeNow) }
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            footer
        }
        .padding(20)
        .frame(width: 600)
        .onChange(of: destination) { _, newValue in
            Task {
                do { cleanup = try await library.cleanupPlan(cleanup.cleanup, destination: newValue) } catch { failure = error.localizedDescription }
            }
        }
    }

    private var changes: some View {
        List {
            CommandsSection(commands: plan.commands)
            if !plan.moves.isEmpty {
                Section("Moved to \(destination.displayName)") {
                    ForEach(plan.moves, id: \.source) { move in
                        ChangeRow(
                            symbol: move.kind == .folder ? "folder" : "doc",
                            path: displayPath(move.source) + (move.kind == .folder ? "/" : ""),
                            note: move.note,
                            size: move.sizeBytes.formatted(.byteCount(style: .file))
                        )
                    }
                }
            }
            if !plan.compressions.isEmpty {
                Section("Compressed in place") {
                    ForEach(plan.compressions, id: \.file) { item in
                        ChangeRow(
                            symbol: "doc.zipper",
                            path: displayPath(item.file),
                            note: item.note,
                            size: "\(item.sizeBytes.formatted(.byteCount(style: .file))) \u{2192} ~\(item.estimatedBytes.formatted(.byteCount(style: .file)))"
                        )
                    }
                }
            }
            if !cleanup.excluded.isEmpty {
                Section("Kept as they are") {
                    ForEach(cleanup.excluded, id: \.url) { item in
                        ChangeRow(symbol: "lock", path: displayPath(item.url), note: item.reason, size: item.sizeBytes.formatted(.byteCount(style: .file)))
                    }
                }
            }
        }
        .frame(height: 220)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !compresses && plan.commands.isEmpty {
                Text("Destination:")
                Picker("Destination", selection: $destination) {
                    Text("Trash").tag(Destination.trash)
                    Text("Domovy quarantine").tag(Destination.quarantine)
                }
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        let title = compresses ? "Compress" : purgeNow && plan.keepsToolCopies ? "Delete Now" : plan.isPermanent ? "Delete" : (destination == .trash ? "Move to Trash" : "Move to Quarantine")
        let button = Button(title, action: execute)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!cleanup.canExecute || isExecuting)
        // With a kept copy a tool command stays undoable; red only once it is for good.
        let permanent = plan.keepsToolCopies ? purgeNow : plan.isPermanent
        if (cleanup.hasConsequences || permanent) && !compresses {
            button.tint(.red)
        } else {
            button
        }
    }

    private func displayPath(_ url: URL) -> String {
        let relative = relativePath(url, under: library.home)
        return relative == url.standardizedFileURL.path ? relative : "~/" + relative
    }

    private func execute() {
        isExecuting = true
        Task {
            do {
                try await library.runCleanup(cleanup, purgeNow: purgeNow && plan.keepsToolCopies)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isExecuting = false
            }
        }
    }
}
