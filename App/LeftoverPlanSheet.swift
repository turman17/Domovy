import DomovyCore
import SwiftUI

/// Leftover worktrees and build output awaiting confirmation.
struct LeftoverRequest: Identifiable {
    let id = UUID()
    let report: LeftoverReport
    let selection: Set<URL>
    let includingWork: Set<URL>
}

/// Every candidate with a checkbox, the exact plan for the ticked ones (checked again on every
/// change), what stays and why, then Cancel / Move to Trash. A worktree with work only it holds
/// is never ticked by default and needs an explicit OK.
struct LeftoverPlanSheet: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    let report: LeftoverReport
    @State private var selection: Set<URL>
    @State private var includingWork: Set<URL>
    @State private var destination: Destination = AppSettings.shared.settings.deleteDestination
    @State private var leftover: LeftoverPlan?
    @State private var acknowledged = false
    @State private var isExecuting = false
    @State private var failure: String?

    init(request: LeftoverRequest) {
        report = request.report
        _selection = State(initialValue: request.selection)
        _includingWork = State(initialValue: request.includingWork)
    }

    private struct PlanKey: Hashable {
        let selection: Set<URL>
        let includingWork: Set<URL>
        let destination: Destination
    }

    private var bytes: Int64 { leftover?.plan.totalBytes ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove leftover checkouts and build output?")
                .font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(bytes.formatted(.byteCount(style: .file)))
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                    .help("\(bytes.formatted()) bytes on disk")
                Text("on disk now")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if let leftover {
                Text(leftover.summary)
                    .foregroundStyle(.secondary)
                checkRow(leftover.plan.liveCheck)
                RemarksView(remarks: leftover.plan.remarks)
            } else {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Checking folders")
            }
            candidates
            if let text = leftover?.plan.acknowledgement {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Remove anyway, with the work only it holds", isOn: $acknowledged)
                        .fontWeight(.semibold)
                    Label(text, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, 20)
                }
                .accessibilityElement(children: .combine)
            }
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            footer
        }
        .padding(20)
        .frame(width: 640)
        .task(id: PlanKey(selection: selection, includingWork: includingWork, destination: destination)) {
            acknowledged = false
            let plan = await library.leftoverPlan(selection, includingWork: includingWork, in: report, destination: destination)
            guard !Task.isCancelled else { return }
            leftover = plan
        }
    }

    private func checkRow(_ result: LiveCheckResult) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: result.isLive ? "dot.radiowaves.left.and.right" : "checkmark.circle.fill")
                .foregroundStyle(result.isLive ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
            Text(result.isLive ? "Blocked" : "Not in use")
                .fontWeight(.semibold)
            Text(result.isLive ? result.reasons.joined(separator: " ") : "No live session, no process working there, no open files. Checked just now.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var candidates: some View {
        List {
            ForEach(report.groups) { group in
                let worktrees = group.worktrees.filter(\.isLeftover)
                let outputs = group.buildOutputs.filter(\.isRemovable)
                if !worktrees.isEmpty || !outputs.isEmpty {
                    Section(group.name) {
                        ForEach(worktrees) { worktree in
                            row(worktree.url, symbol: "arrow.triangle.branch", note: worktree.state.reason, size: worktree.sizeBytes, in: $selection)
                        }
                        ForEach(outputs) { output in
                            row(output.url, symbol: "shippingbox", note: "Safe: rebuildable. \(output.kind.explanation)\(output.isInMainCheckout ? " In the main checkout." : "")",
                                size: output.sizeBytes, in: $selection)
                        }
                    }
                }
            }
            let withWork = report.worktrees.filter(\.hasWork)
            if !withWork.isEmpty {
                Section("Has work only it holds \u{00B7} kept unless you tick it") {
                    ForEach(withWork) { worktree in
                        row(worktree.url, symbol: "exclamationmark.triangle.fill", note: worktree.state.reason, size: worktree.sizeBytes, in: $includingWork)
                    }
                }
            }
            if let excluded = leftover?.excluded, !excluded.isEmpty {
                Section("Kept as they are") {
                    ForEach(excluded, id: \.url) { item in
                        ChangeRow(symbol: "lock", path: displayPath(item.url), note: item.reason, size: item.sizeBytes.formatted(.byteCount(style: .file)))
                    }
                }
            }
        }
        .frame(height: 260)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ url: URL, symbol: String, note: String, size: Int64, in set: Binding<Set<URL>>) -> some View {
        Toggle(isOn: Binding(
            get: { set.wrappedValue.contains(url) },
            set: { if $0 { set.wrappedValue.insert(url) } else { set.wrappedValue.remove(url) } }
        )) {
            ChangeRow(symbol: symbol, path: displayPath(url) + "/", note: note, size: size.formatted(.byteCount(style: .file)))
        }
        .toggleStyle(.checkbox)
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
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            primaryButton
        }
    }

    /// Why the button is off, when it is.
    private var primaryHelp: String {
        guard let leftover else { return "Still checking the folders" }
        if leftover.isBlocked { return "Something is using these folders; see above" }
        if leftover.plan.isEmpty { return "Tick at least one folder" }
        if leftover.plan.acknowledgement != nil && !acknowledged { return "Tick \u{201C}Remove anyway\u{201D} first" }
        return "You can undo this"
    }

    @ViewBuilder
    private var primaryButton: some View {
        let ready = leftover.map { !$0.isBlocked && !$0.plan.isEmpty && ($0.plan.acknowledgement == nil || acknowledged) } ?? false
        let button = Button(destination == .trash ? "Move to Trash" : "Move to Quarantine", action: execute)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(!ready || isExecuting)
            .help(primaryHelp)
        // Red only when worktrees move: git keeps a stale entry, and work may go with them.
        if leftover?.hasConsequences == true {
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
        guard var leftover else { return }
        leftover.plan.isAcknowledged = acknowledged
        isExecuting = true
        Task {
            do {
                try await library.runLeftovers(leftover)
                dismiss()
            } catch {
                failure = error.localizedDescription
                isExecuting = false
            }
        }
    }
}
