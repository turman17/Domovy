import DomovyCore
import SwiftUI

/// An orphan or duplicate cleanup awaiting confirmation.
struct OrphanRequest: Identifiable {
    let id = UUID()
    let scope: OrphanScope
    let plan: Plan
}

/// Every item the cleanup moves and every Desktop entry it removes, grouped by what it is,
/// with the total, the destination and the live and Claude Desktop checks.
struct OrphanPlanSheet: View {
    let request: OrphanRequest

    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var plan: Plan
    @State private var destination: Destination
    @State private var isExecuting = false
    @State private var failure: String?

    init(request: OrphanRequest) {
        self.request = request
        _plan = State(initialValue: request.plan)
        _destination = State(initialValue: request.plan.destination ?? .trash)
    }

    private var title: String {
        request.scope == .orphans ? "Clean up what was left behind?" : "Remove duplicate copies?"
    }

    /// Moves grouped by their note's kind ("Companion of …", "Older copy …"), in plan order.
    private var groups: [(title: String, moves: [FileMove])] {
        var order: [String] = []
        var byTitle: [String: [FileMove]] = [:]
        for move in plan.moves {
            let title = Self.groupTitle(for: move.note)
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(move)
        }
        return order.map { ($0, byTitle[$0] ?? []) }
    }

    private static func groupTitle(for note: String) -> String {
        if note.hasPrefix("Companion") { return "Companion folders whose transcript is gone" }
        if note.hasPrefix("Older copy") { return "Set-aside copies of a transcript" }
        return "Earlier transcripts of a continued Desktop conversation"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(plan.summary)
                .foregroundStyle(.secondary)
            LiveCheckRow(result: plan.liveCheck)
            RemarksView(remarks: plan.remarks)
            List {
                ForEach(groups, id: \.title) { group in
                    Section("\(group.title) · moved to \(destination.displayName)") {
                        ForEach(group.moves, id: \.source) { move in
                            ChangeRow(
                                symbol: move.kind == .folder ? "folder" : "doc",
                                path: relativePath(move.source, under: library.claudeCode.root) + (move.kind == .folder ? "/" : ""),
                                note: move.note,
                                size: move.sizeBytes.formatted(.byteCount(style: .file))
                            )
                        }
                    }
                }
                if !plan.registryRemovals.isEmpty {
                    Section("Claude Desktop session list · backup kept") {
                        RegistryRemovalRows(removals: plan.registryRemovals)
                    }
                }
            }
            .frame(height: 300)
            .scrollContentBackground(.hidden)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
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
                do { plan = try await library.orphanPlan(request.scope, destination: newValue) } catch { failure = error.localizedDescription }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Destination:")
            Picker("Destination", selection: $destination) {
                Text("Trash").tag(Destination.trash)
                Text("Domovy quarantine").tag(Destination.quarantine)
            }
            .labelsHidden()
            .fixedSize()
            SizeText(bytes: plan.totalBytes)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(destination == .trash ? "Move to Trash" : "Move to Quarantine", action: execute)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(plan.liveCheck.isLive || plan.isEmpty || isExecuting)
        }
    }

    private func execute() {
        isExecuting = true
        Task {
            do {
                try await library.cleanUp(plan, scope: request.scope)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isExecuting = false
            }
        }
    }
}
