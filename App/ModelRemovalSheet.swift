import DomovyCore
import SwiftUI

/// Local models awaiting confirmation.
struct ModelRemovalRequest: Identifiable {
    let id = UUID()
    let removal: ModelRemovalPlan
}

/// Removing local models: per tool, the command it runs (after Domovy keeps a copy) or the files
/// that move, the running and loaded checks, and the shared layers that stay.
struct ModelRemovalSheet: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var removal: ModelRemovalPlan
    @State private var destination: Destination
    @State private var isExecuting = false
    @State private var failure: String?

    init(request: ModelRemovalRequest) {
        _removal = State(initialValue: request.removal)
        _destination = State(initialValue: request.removal.plans.compactMap(\.destination).first ?? .trash)
    }

    private var movesFiles: Bool { removal.plans.contains { !$0.moves.isEmpty } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(removal.title)
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(removal.totalBytes.formatted(.byteCount(style: .file)))
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                    .help("\(removal.totalBytes.formatted()) bytes on disk")
                Text(removal.isPermanent ? "freed when you purge Domovy's copy" : "freed on disk")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Text(removal.summary)
                .foregroundStyle(.secondary)
            LiveCheckRow(result: removal.liveCheck)
            RemarksView(remarks: removal.plans.flatMap(\.remarks))
            changes
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
                do { removal = try await library.modelRemovalPlan(removal.models, destination: newValue) } catch { failure = error.localizedDescription }
            }
        }
    }

    private var changes: some View {
        List {
            ForEach(removal.plans) { plan in
                if !plan.commands.isEmpty {
                    Section("\(plan.agent.displayName) · copy kept, deleted by its own command, then checked") {
                        ForEach(plan.commands, id: \.self) { command in
                            ChangeRow(symbol: "terminal", path: command.commandLine, note: command.note,
                                      size: command.sizeBytes.formatted(.byteCount(style: .file)))
                        }
                    }
                }
                if !plan.moves.isEmpty {
                    Section("\(plan.agent.displayName) · moved to \(destination.displayName)") {
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
            }
            if !removal.excluded.isEmpty {
                Section("Kept: other models use these") {
                    ForEach(removal.excluded, id: \.url) { item in
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
            if movesFiles {
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
            Button(confirmTitle, action: execute)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!removal.canExecute || isExecuting)
        }
    }

    /// "Delete" when the tools delete (Domovy keeps a copy), "Move to Trash" when files only move.
    private var confirmTitle: String {
        if !removal.isPermanent { return destination == .trash ? "Move to Trash" : "Move to Quarantine" }
        return movesFiles ? "Remove" : "Delete"
    }

    private func displayPath(_ url: URL) -> String {
        let relative = relativePath(url, under: library.home)
        return relative == url.standardizedFileURL.path ? relative : "~/" + relative
    }

    private func execute() {
        isExecuting = true
        Task {
            do {
                try await library.runModelRemoval(removal)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isExecuting = false
            }
        }
    }
}
