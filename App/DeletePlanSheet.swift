import DomovyCore
import SwiftUI

/// Shows the exact plan before anything moves: every file and index entry, the total, the
/// destination and the live check. Return confirms, Escape cancels.
struct DeletePlanSheet: View {
    let request: DeleteRequest

    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var plan: Plan
    @State private var destination: Destination
    @State private var isExecuting = false
    @State private var failure: String?

    init(request: DeleteRequest) {
        self.request = request
        _plan = State(initialValue: request.plan)
        _destination = State(initialValue: request.plan.destination ?? .trash)
    }

    private var root: URL { library.root(for: plan.agent) }
    private var confirmTitle: String { destination == .trash ? "Move to Trash" : "Move to Quarantine" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete session \u{201C}\(request.session.displayTitle)\u{201D}?")
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
        .onChange(of: destination) { _, newValue in
            Task {
                do { plan = try await library.deletePlan(for: request.session, destination: newValue) } catch { failure = error.localizedDescription }
            }
        }
    }

    private var changes: some View {
        List {
            CommandsSection(commands: plan.commands)
            Section("\(plan.agent.displayName) · \(abbreviatedRoot) · moved to \(destination.displayName)") {
                ForEach(plan.moves, id: \.source) { move in
                    ChangeRow(
                        symbol: move.kind == .folder ? "folder" : "doc",
                        path: relativePath(move.source, under: root) + (move.kind == .folder ? "/" : ""),
                        note: move.note,
                        size: move.sizeBytes.formatted(.byteCount(style: .file))
                    )
                }
            }
            if !plan.indexEdits.isEmpty {
                Section("Index entries · edited in place, backup kept") {
                    ForEach(plan.indexEdits, id: \.file) { edit in
                        ChangeRow(symbol: "list.bullet.rectangle", path: relativePath(edit.file, under: root), note: edit.note, size: "–")
                    }
                }
            }
        }
        .frame(height: 320)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var abbreviatedRoot: String {
        "~/" + relativePath(root, under: root.deletingLastPathComponent())
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
            Button(confirmTitle, action: execute)
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
                try await library.execute(plan, for: request.session)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isExecuting = false
            }
        }
    }
}

struct ChangeRow: View {
    let symbol: String
    let path: String
    let note: String
    let size: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(size)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The agent's own commands a plan runs, e.g. "Runs codex delete … then checks the result".
struct CommandsSection: View {
    let commands: [PlannedCommand]

    var body: some View {
        if !commands.isEmpty {
            Section("\(commands.first?.executable.lastPathComponent ?? "Agent") command · run first, then checked") {
                ForEach(commands, id: \.self) { command in
                    ChangeRow(
                        symbol: "terminal",
                        path: command.commandLine,
                        note: command.note,
                        size: command.sizeBytes > 0 ? command.sizeBytes.formatted(.byteCount(style: .file)) : "–"
                    )
                }
            }
        }
    }
}

/// Consequences the user should know before confirming, one line each.
struct RemarksView: View {
    let remarks: [String]

    var body: some View {
        ForEach(remarks, id: \.self) { remark in
            Label(remark, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

/// Green check when nothing uses the session; gray broadcast symbol with the reasons otherwise.
struct LiveCheckRow: View {
    let result: LiveCheckResult

    private var detail: String {
        if result.isLive { return result.reasons.joined(separator: " ") }
        var parts: [String] = []
        switch result.openHandles {
        case .clear: parts.append("No open file handles")
        case .open: parts.append("Open file handles found")
        case .unavailable: parts.append("File handles could not be checked")
        }
        if result.checkedSignals.contains("daemon/roster.json") { parts.append("not in Claude's session roster") }
        if result.checkedSignals.contains("thread-writer-locks") { parts.append("Codex does not have it open") }
        if result.checkedSignals.contains("Codex processes") { parts.append("Codex is not running") }
        return parts.joined(separator: ", ") + ". Checked just now."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.isLive ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill")
                .foregroundStyle(result.isLive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
            Text(result.isLive ? (result.reasons.allSatisfy { $0.contains("is running") } ? "Blocked" : "Running") : "Not running")
                .fontWeight(.semibold)
            Text(detail)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .background((result.isLive ? Color.secondary : Color.green).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
