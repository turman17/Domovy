import DomovyCore
import SwiftUI

/// Shows the exact plan before anything moves: every file and index entry, the total, the
/// destination and the live check, grouped per session for a batch. Return confirms, Escape
/// cancels.
struct DeletePlanSheet: View {
    let request: DeleteRequest

    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var plans: [Plan]
    @State private var destination: Destination
    @State private var isExecuting = false
    @State private var failure: String?
    @State private var purgeNow = false
    @State private var acknowledged = false

    init(request: DeleteRequest) {
        self.request = request
        _plans = State(initialValue: request.plans)
        _destination = State(initialValue: request.plans.first?.destination ?? .trash)
    }

    private var isBatch: Bool { plans.count > 1 }
    private var totalBytes: Int64 { plans.reduce(0) { $0 + $1.totalBytes } }
    private var keepsToolCopies: Bool { plans.contains(where: \.keepsToolCopies) }
    private var acknowledgements: [String] { Array(Set(plans.compactMap(\.acknowledgement))).sorted() }
    private var isLive: Bool { plans.contains { $0.liveCheck.isLive } }
    private var secretCount: Int { request.sessions.reduce(0) { $0 + library.findings(for: $1).count } }

    private var confirmTitle: String {
        let what = isBatch ? " \(plans.count) Sessions" : ""
        if purgeNow && keepsToolCopies { return "Delete Now" }
        if plans.allSatisfy({ (!$0.commands.isEmpty || !$0.databaseEdits.isEmpty) && $0.moves.isEmpty }) { return "Delete" + what }
        return "Move\(what) to " + (destination == .trash ? "Trash" : "Quarantine")
    }

    private var title: String {
        isBatch ? "Delete \(plans.count) sessions?" : "Delete session \u{201C}\(request.sessions[0].displayTitle)\u{201D}?"
    }

    private var summary: String {
        guard isBatch else { return plans.first?.summary ?? "" }
        let moved = plans.reduce(0) { $0 + $1.moves.count }
        var parts = ["Changes \(plans.count) sessions (\(totalBytes.formatted(.byteCount(style: .file))))."]
        if moved > 0 { parts.append("Moves \(moved) \(moved == 1 ? "file or folder" : "files and folders") to \(destination.displayName).") }
        parts.append("Every change is listed below, grouped by session.")
        return parts.joined(separator: " ")
    }

    /// One live check per agent: a batch is checked with the same signals for each session.
    private var liveChecks: [Plan] {
        if let live = plans.first(where: { $0.liveCheck.isLive }) { return [live] }
        var seen: Set<AgentKind> = []
        return plans.filter { seen.insert($0.agent).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(summary)
                .foregroundStyle(.secondary)
            ForEach(request.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(liveChecks) { plan in
                LiveCheckRow(result: plan.liveCheck)
            }
            RemarksView(remarks: Array(Set(plans.flatMap(\.remarks))).sorted())
            secretsHint
            changes
            if keepsToolCopies { FreeSpaceNowToggle(isOn: $purgeNow) }
            if !acknowledgements.isEmpty { AcknowledgementToggle(text: acknowledgements.joined(separator: " "), isOn: $acknowledged) }
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
                do {
                    var replanned: [Plan] = []
                    for session in request.sessions {
                        replanned.append(try await library.deletePlan(for: session, destination: newValue))
                    }
                    plans = replanned
                } catch {
                    failure = error.localizedDescription
                }
            }
        }
    }

    /// The Trash keeps plaintext; say so when the scan flagged these sessions.
    @ViewBuilder
    private var secretsHint: some View {
        let count = secretCount
        if count > 0 {
            Label(
                "The secret scan found \(count) possible \(count == 1 ? "secret" : "secrets") here. The Trash keeps files in plain text until it is emptied. The Domovy quarantine keeps them out of the Trash; remove them for good later with Secrets \u{203A} Purge Originals.",
                systemImage: "key.fill"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var changes: some View {
        List {
            ForEach(plans) { plan in
                PlanChanges(plan: plan, sessionTitle: isBatch ? title(of: plan) : nil, root: library.root(for: plan.agent), destination: destination)
            }
        }
        .frame(height: 320)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func title(of plan: Plan) -> String {
        request.sessions.first { $0.id == plan.sessionID }?.displayTitle ?? plan.sessionID
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
            SizeText(bytes: totalBytes)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: execute)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                // With a kept copy the delete stays undoable; red only once it is for good.
                .tint(!keepsToolCopies || purgeNow ? .red : nil)
                .disabled(isLive || plans.isEmpty || plans.contains(where: \.isEmpty) || isExecuting || (!acknowledgements.isEmpty && !acknowledged))
        }
    }

    private func execute() {
        isExecuting = true
        let plans = plans.map { plan in
            var plan = plan
            plan.isAcknowledged = acknowledged
            return plan
        }
        Task {
            do {
                try await library.execute(plans, for: request.sessions, purgeNow: purgeNow && keepsToolCopies)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isExecuting = false
            }
        }
    }
}

/// One plan's rows: the agent's commands, database rows, moved files and index entries.
/// In a batch every section header starts with the session's title.
private struct PlanChanges: View {
    let plan: Plan
    let sessionTitle: String?
    let root: URL
    let destination: Destination

    private var prefix: String { sessionTitle.map { "\u{201C}\($0)\u{201D} · " } ?? "" }

    private var abbreviatedRoot: String {
        "~/" + relativePath(root, under: root.deletingLastPathComponent())
    }

    var body: some View {
        CommandsSection(commands: plan.commands)
        DatabaseEditSection(edits: plan.databaseEdits)
        if !plan.moves.isEmpty || sessionTitle == nil {
            Section(prefix + "\(plan.agent.displayName) · \(abbreviatedRoot) · moved to \(destination.displayName)") {
                ForEach(plan.moves, id: \.source) { move in
                    ChangeRow(
                        symbol: move.kind == .folder ? "folder" : "doc",
                        path: relativePath(move.source, under: root) + (move.kind == .folder ? "/" : ""),
                        note: move.note,
                        size: move.sizeBytes.formatted(.byteCount(style: .file))
                    )
                }
            }
        }
        if !plan.indexEdits.isEmpty || !plan.registryRemovals.isEmpty {
            Section(prefix + "Index entries · edited in place, backup kept") {
                ForEach(plan.indexEdits, id: \.file) { edit in
                    ChangeRow(symbol: "list.bullet.rectangle", path: relativePath(edit.file, under: root), note: edit.note, size: "–")
                }
                RegistryRemovalRows(removals: plan.registryRemovals)
            }
        }
    }
}

/// Claude Desktop registry entries a plan removes, with their path under Application Support.
struct RegistryRemovalRows: View {
    let removals: [RegistryRemoval]

    var body: some View {
        ForEach(removals, id: \.file) { removal in
            ChangeRow(
                symbol: "macwindow",
                path: "Claude/" + relativePath(removal.file, under: removal.file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()),
                note: removal.note,
                size: removal.sizeBytes.formatted(.byteCount(style: .file))
            )
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

/// Rows Domovy deletes from an app's database itself (Cursor's state.vscdb), each prefix one row.
struct DatabaseEditSection: View {
    let edits: [DatabaseEdit]

    var body: some View {
        ForEach(edits.filter { !$0.isEmpty }, id: \.database) { edit in
            Section("\(edit.database.lastPathComponent) · rows deleted in place, whole-file copy kept, integrity checked") {
                ForEach(edit.rows, id: \.key) { rows in
                    ChangeRow(
                        symbol: "tablecells",
                        path: rows.isPrefix ? "\(rows.key)\u{2026}" : rows.key,
                        note: "\(rows.note) · \(rows.count) \(rows.count == 1 ? "row" : "rows")",
                        size: rows.bytes.formatted(.byteCount(style: .file))
                    )
                }
                ForEach(edit.listRemovals, id: \.key) { removal in
                    ChangeRow(symbol: "list.bullet.rectangle", path: removal.key, note: removal.note, size: "\u{2013}")
                }
            }
        }
    }
}

/// Opt-in, off by default: delete Domovy's kept copy right after the tool's command succeeded,
/// so the space comes back now. Undo is no longer possible then.
struct FreeSpaceNowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Free the space now (can't undo)", isOn: $isOn)
            Text("Domovy keeps a copy so you can undo. With this on, it deletes that copy right after the command succeeds.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Off by default: the user accepts, in so many words, that undo may stop working (OpenCode's
/// database once OpenCode writes to it again). The confirm button waits for it.
struct AcknowledgementToggle: View {
    let text: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("I understand undo may not be possible", isOn: $isOn)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 20)
        }
        .accessibilityElement(children: .combine)
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
        if result.checkedSignals.contains("Claude Desktop processes") { parts.append("Claude Desktop is not running") }
        if result.checkedSignals.contains("Ollama processes") { parts.append("Ollama is not running") }
        if result.checkedSignals.contains("LM Studio processes") { parts.append("LM Studio is not running") }
        if result.checkedSignals.contains("Gemini CLI processes") { parts.append("Gemini CLI is not running") }
        if result.checkedSignals.contains("OpenCode processes") { parts.append("OpenCode is not using its database") }
        if result.checkedSignals.contains("Copilot CLI processes") { parts.append("Copilot CLI is not running") }
        if result.checkedSignals.contains("Cursor processes") { parts.append("Cursor is not running") }
        if result.checkedSignals.contains("ollama ps") { parts.append("the model is not loaded in Ollama") }
        return parts.joined(separator: ", ") + ". Checked just now."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.isLive ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill")
                .foregroundStyle(result.isLive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
            Text(result.isLive ? (result.reasons.allSatisfy { $0.contains("is running") || $0.contains("is loaded") } ? "Blocked" : "Running") : "Not running")
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
