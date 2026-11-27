import DomovyCore
import SwiftUI

/// Shows the exact plan before anything moves: every file and index entry, the total, the
/// destination and the live check, one group per session in a batch. Opens at once and plans
/// while it shows a spinner. Return confirms, Escape cancels.
struct DeletePlanSheet: View {
    let request: DeleteRequest

    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    /// Nil while planning.
    @State private var plans: [Plan]?
    /// Sessions the plans left out ("1 live session is left alone.").
    @State private var dropped: [String] = []
    @State private var destination: Destination
    @State private var failure: String?
    @State private var purgeNow = false
    @State private var acknowledged = false

    init(request: DeleteRequest) {
        self.request = request
        _destination = State(initialValue: request.destination)
    }

    private var planned: [Plan] { plans ?? [] }
    private var isBatch: Bool { request.sessions.count > 1 }
    private var totalBytes: Int64 { planned.reduce(0) { $0 + $1.totalBytes } }
    private var keepsToolCopies: Bool { planned.contains(where: \.keepsToolCopies) }
    private var acknowledgements: [String] { Array(Set(planned.compactMap(\.acknowledgement))).sorted() }
    private var isLive: Bool { planned.contains { $0.liveCheck.isLive } }
    private var movesFiles: Bool { planned.contains { !$0.moves.isEmpty } }
    private var plannedSessions: [Session] {
        let ids = Set(planned.map(\.sessionID))
        return request.sessions.filter { ids.contains($0.id) }
    }
    private var secretCount: Int { plannedSessions.reduce(0) { $0 + library.findings(for: $1).count } }

    /// Short so it never truncates; the count is in the title.
    private var confirmTitle: String {
        if purgeNow && keepsToolCopies { return "Delete Now" }
        if !movesFiles { return "Delete" }
        return destination == .trash ? "Move to Trash" : "Move to Quarantine"
    }

    private var title: String {
        let what = planned.count > 1 || isBatch ? "\(planned.count) sessions" : "\u{201C}\(request.sessions[0].displayTitle)\u{201D}"
        return movesFiles ? "Move \(what) to \(destination.displayName)?" : "Delete \(what)?"
    }

    private var summary: String {
        guard planned.count > 1 else { return planned.first?.summary ?? "" }
        let moved = planned.reduce(0) { $0 + $1.moves.count }
        var parts: [String] = []
        if moved > 0 { parts.append("Moves \(moved) \(moved == 1 ? "file or folder" : "files and folders") (\(totalBytes.formatted(.byteCount(style: .file)))).") }
        parts.append("Every change is listed below, one group per session.")
        return parts.joined(separator: " ")
    }

    /// One live check per agent: a batch is checked with the same signals for each session.
    private var liveChecks: [Plan] {
        if let live = planned.first(where: { $0.liveCheck.isLive }) { return [live] }
        var seen: Set<AgentKind> = []
        return planned.filter { seen.insert($0.agent).inserted }
    }

    var body: some View {
        Group {
            if plans == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Checking \(isBatch ? "\(request.sessions.count) sessions" : "the session")\u{2026}")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                .frame(maxWidth: .infinity, minHeight: 160)
            } else if planned.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Nothing to delete")
                        .font(.title3.weight(.semibold))
                    ForEach(nothingToDoReasons, id: \.self) { reason in
                        Text(reason)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if !isBatch, let session = request.sessions.first {
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
        .task(id: destination) {
            await plan()
            #if DEBUG
            PerfDriver.shared.planShown = true
            #endif
        }
    }

    /// Why the sheet has nothing to confirm: never empty.
    private var nothingToDoReasons: [String] {
        let reasons = ([failure].compactMap { $0 } + request.notes + dropped).filter { !$0.isEmpty }
        return reasons.isEmpty ? ["Nothing in \(isBatch ? "these sessions" : "this session") can be deleted right now."] : reasons
    }

    /// Plans every session in one go. In a batch, live sessions, ones with nothing to change
    /// and ones that cannot be planned drop out with a note saying why; a single one stays so
    /// the sheet can say why.
    private func plan() async {
        failure = nil
        let results = await library.deletePlans(for: request.sessions, destination: destination)
        if !isBatch, let result = results.first {
            switch result.result {
            case .success(let plan) where plan.isEmpty && !plan.liveCheck.isLive:
                // Nothing to change: the plan's own words say why.
                failure = plan.remarks.isEmpty ? plan.summary : plan.remarks.joined(separator: " ")
                plans = []
            case .success(let plan): plans = [plan]
            case .failure(let error):
                failure = error.localizedDescription
                plans = []
            }
            return
        }
        let ok = results.compactMap(\.plan)
        let live = ok.filter(\.liveCheck.isLive)
        let empty = ok.filter { !$0.liveCheck.isLive && $0.isEmpty }
        var notes: [String] = []
        if !live.isEmpty {
            let n = live.count
            let why = Array(NSOrderedSet(array: live.flatMap(\.liveCheck.reasons))).compactMap { $0 as? String }.prefix(2).joined(separator: " ")
            notes.append("\(n) live \(n == 1 ? "session is" : "sessions are") left alone.\(why.isEmpty ? "" : " \(why)")")
        }
        // Grouped by what they say, so eight of one agent read as one line.
        for (reason, n) in Self.counted(empty.map { $0.remarks.first ?? $0.summary }) {
            notes.append("\(n) \(n == 1 ? "session has" : "sessions have") nothing to delete: \(reason)")
        }
        let errors = results.compactMap { result -> String? in
            if case .failure(let error) = result.result { return error.localizedDescription }
            return nil
        }
        for (reason, n) in Self.counted(errors) {
            notes.append("\(n) \(n == 1 ? "session could" : "sessions could") not be planned and \(n == 1 ? "is" : "are") left alone: \(reason)")
        }
        dropped = notes
        plans = ok.filter { !$0.liveCheck.isLive && !$0.isEmpty }
    }

    /// Distinct texts with how often each came up, in first-seen order.
    private static func counted(_ texts: [String]) -> [(String, Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for text in texts {
            if counts[text] == nil { order.append(text) }
            counts[text, default: 0] += 1
        }
        return order.map { ($0, counts[$0] ?? 0) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(summary)
                .foregroundStyle(.secondary)
            ForEach(request.notes + dropped, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(liveChecks) { plan in
                LiveCheckRow(result: plan.liveCheck)
            }
            // In a batch each session's remarks sit in its own group below.
            if planned.count == 1, let plan = planned.first { RemarksView(remarks: plan.remarks) }
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
            if planned.count == 1, let plan = planned.first {
                PlanChanges(plan: plan, root: library.root(for: plan.agent), destination: destination)
            } else {
                ForEach(planned) { plan in
                    SessionChanges(plan: plan, session: plannedSessions.first { $0.id == plan.sessionID }, root: library.root(for: plan.agent))
                }
            }
        }
        .frame(height: 320)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Picker("Destination", selection: $destination) {
                Text("Trash").tag(Destination.trash)
                Text("Domovy quarantine").tag(Destination.quarantine)
            }
            .labelsHidden()
            .fixedSize()
            .help("Where the files go")
            SizeText(bytes: totalBytes)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .fixedSize()
            Button(confirmTitle, action: execute)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .fixedSize()
                // With a kept copy the delete stays undoable; red only once it is for good.
                .tint(!keepsToolCopies || purgeNow ? .red : nil)
                .disabled(isLive || planned.isEmpty || planned.contains(where: \.isEmpty) || (!acknowledgements.isEmpty && !acknowledged))
        }
    }

    /// Closes the sheet at once; the delete runs in the background and ends in a toast.
    private func execute() {
        let plans = planned.map { plan in
            var plan = plan
            plan.isAcknowledged = acknowledged
            return plan
        }
        let sessions = plannedSessions
        let purge = purgeNow && keepsToolCopies
        let moves = movesFiles
        let n = plans.count
        let what = n == 1 ? "1 session" : "\(n) sessions"
        library.runInBackground(
            moves ? "Moving \(what) to \(destination.displayName)\u{2026}" : "Deleting \(what)\u{2026}",
            status: moves ? "Moving\u{2026}" : "Deleting\u{2026}",
            sessions: plans.map(\.sessionID)
        ) { [library] in
            try await library.execute(plans, for: sessions, purgeNow: purge)
        }
        dismiss()
    }
}

/// One plan's rows in the single-session sheet: the agent's commands, database rows, moved
/// files and index entries, each kind under its own header.
private struct PlanChanges: View {
    let plan: Plan
    let root: URL
    let destination: Destination

    private var abbreviatedRoot: String {
        "~/" + relativePath(root, under: root.deletingLastPathComponent())
    }

    var body: some View {
        CommandsSection(commands: plan.commands)
        DatabaseEditSection(edits: plan.databaseEdits)
        Section("\(plan.agent.displayName) · \(abbreviatedRoot) · moved to \(destination.displayName)") {
            ForEach(plan.moves, id: \.source) { move in
                MoveRow(move: move, root: root)
            }
        }
        if !plan.indexEdits.isEmpty || !plan.registryRemovals.isEmpty || !plan.jsonRemovals.isEmpty {
            Section("Index entries · edited in place, backup kept") {
                ForEach(plan.indexEdits, id: \.file) { edit in
                    ChangeRow(symbol: "list.bullet.rectangle", path: relativePath(edit.file, under: root), note: edit.note, size: "–")
                }
                JSONRemovalRows(removals: plan.jsonRemovals, root: root)
                RegistryRemovalRows(removals: plan.registryRemovals)
            }
        }
    }
}

/// One session of a batch: a header that tells sessions apart (title, project, when), its own
/// remarks, then every change it makes.
private struct SessionChanges: View {
    let plan: Plan
    let session: Session?
    let root: URL

    private var header: String {
        guard let session else { return plan.sessionID }
        return [
            "\u{201C}\(session.displayTitle)\u{201D}",
            session.projectName ?? session.agent.displayName,
            session.lastActive.formatted(.relative(presentation: .named)),
        ].joined(separator: " · ")
    }

    var body: some View {
        Section {
            ForEach(plan.remarks, id: \.self) { remark in
                Label(remark, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(plan.commands, id: \.self) { command in
                ChangeRow(symbol: "terminal", path: command.commandLine, note: command.note,
                          size: command.sizeBytes > 0 ? command.sizeBytes.formatted(.byteCount(style: .file)) : "–")
            }
            ForEach(plan.databaseEdits.filter { !$0.isEmpty }, id: \.database) { edit in
                ForEach(edit.rows, id: \.key) { rows in
                    ChangeRow(symbol: "tablecells", path: "\(edit.database.lastPathComponent): \(rows.isPrefix ? "\(rows.key)\u{2026}" : rows.key)",
                              note: "\(rows.note) · \(rows.count) \(rows.count == 1 ? "row" : "rows") deleted in place, copy kept",
                              size: rows.bytes.formatted(.byteCount(style: .file)))
                }
            }
            ForEach(plan.moves, id: \.source) { move in
                MoveRow(move: move, root: root)
            }
            ForEach(plan.indexEdits, id: \.file) { edit in
                ChangeRow(symbol: "list.bullet.rectangle", path: relativePath(edit.file, under: root), note: edit.note + " · edited in place, backup kept", size: "–")
            }
            JSONRemovalRows(removals: plan.jsonRemovals, root: root)
            RegistryRemovalRows(removals: plan.registryRemovals)
        } header: {
            Text(header)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(header)
        }
    }
}

/// Entries cut out of an app's JSON index (Antigravity's metadata cache).
private struct JSONRemovalRows: View {
    let removals: [JSONMemberRemoval]
    let root: URL

    var body: some View {
        ForEach(removals, id: \.self) { removal in
            ChangeRow(symbol: "list.bullet.rectangle", path: relativePath(removal.file, under: root),
                      note: removal.note + " · edited in place, copy kept", size: removal.sizeBytes.formatted(.byteCount(style: .file)))
        }
    }
}

private struct MoveRow: View {
    let move: FileMove
    let root: URL

    var body: some View {
        ChangeRow(
            symbol: move.kind == .folder ? "folder" : "doc",
            path: relativePath(move.source, under: root) + (move.kind == .folder ? "/" : ""),
            note: move.note,
            size: move.sizeBytes.formatted(.byteCount(style: .file))
        )
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
