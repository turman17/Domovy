import DomovyCore
import SwiftUI

/// Process actions awaiting confirmation: one plan per process tree ("Quit All" has several).
struct ProcessActionRequest: Identifiable {
    let id = UUID()
    let plans: [ProcessActionPlan]
}

/// Shows exactly which processes get which signal, and why anything is refused. A quit that
/// leaves processes running stays open and offers Force Quit as a second, red, explicit step.
struct ProcessActionSheet: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(ProcessMonitor.self) private var monitor
    @Environment(\.dismiss) private var dismiss
    @State private var plans: [ProcessActionPlan]
    @State private var isExecuting = false
    @State private var failure: String?
    /// After a quit: what is still running, as a Force Quit plan.
    @State private var forceQuit: [ProcessActionPlan] = []
    @State private var quitSummary: String?

    init(request: ProcessActionRequest) {
        _plans = State(initialValue: request.plans)
    }

    private var action: ProcessAction { forceQuit.isEmpty ? (plans.first?.action ?? .freeze) : .forceQuit }
    private var current: [ProcessActionPlan] { forceQuit.isEmpty ? plans : forceQuit }
    private var runnable: [ProcessActionPlan] { current.filter(\.canExecute) }
    private var refused: [ProcessActionPlan] { current.filter { !$0.canExecute } }

    private var title: String {
        let what = current.count == 1 ? "\u{201C}\(current[0].rootName)\u{201D}" : "\(current.count) process trees"
        return "\(action.title) \(what)?"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))
            if let quitSummary {
                Label(quitSummary, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(current.enumerated()), id: \.offset) { _, plan in
                Text(plan.summary)
                    .foregroundStyle(.secondary)
            }
            targets
            if let failure {
                Label(failure, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.secondary)
            }
            footer
        }
        .padding(20)
        .frame(width: 520)
    }

    private var targets: some View {
        List {
            ForEach(Array(runnable.enumerated()), id: \.offset) { _, plan in
                Section("\(plan.agent?.displayName ?? "Not traced to an agent") · \(signalName(plan.action))") {
                    ForEach(plan.targets, id: \.self) { target in
                        ChangeRow(symbol: "cpu", path: target.name, note: "pid \(target.pid)",
                                  size: target.footprintBytes.map { $0.formatted(.byteCount(style: .memory)) } ?? "–")
                    }
                }
            }
            if !refused.isEmpty {
                Section("Not changed") {
                    ForEach(Array(refused.enumerated()), id: \.offset) { _, plan in
                        ChangeRow(symbol: "lock", path: plan.rootName, note: plan.refusals.joined(separator: " "), size: "")
                    }
                }
            }
        }
        .frame(height: 180)
        .scrollContentBackground(.hidden)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if forceQuit.isEmpty, let suggestion = refused.compactMap(\.suggestion).first, runnable.isEmpty {
                Button("\(suggestion.title) Instead") { replan(suggestion) }
            }
            Spacer()
            Button(forceQuit.isEmpty ? "Cancel" : "Leave Running") { dismiss() }
                .keyboardShortcut(.cancelAction)
            primary
        }
    }

    @ViewBuilder
    private var primary: some View {
        let button = Button(action.title, action: execute)
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(runnable.isEmpty || isExecuting)
        // Red only for the one step that cannot be undone and gives no chance to clean up.
        if action == .forceQuit { button.tint(.red) } else { button }
    }

    private func signalName(_ action: ProcessAction) -> String {
        switch action {
        case .freeze: "paused with SIGSTOP"
        case .resume: "resumed with SIGCONT"
        case .quit: "asked to exit with SIGTERM"
        case .forceQuit: "ended with SIGKILL"
        }
    }

    private func replan(_ suggestion: ProcessAction) {
        do {
            plans = try plans.compactMap { $0.targets.first?.pid }.map { try monitor.plan(suggestion, pid: $0) }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func execute() {
        isExecuting = true
        let batch = runnable
        Task {
            var results: [(ProcessActionPlan, ProcessActionResult)] = []
            do {
                for plan in batch { results.append((plan, try await monitor.execute(plan))) }
            } catch {
                failure = error.localizedDescription
                isExecuting = false
                return
            }
            let summary = results.map(\.1.summary).joined(separator: " ")
            let leftovers = results.filter { !$0.1.stillRunning.isEmpty }
            if action == .quit, !leftovers.isEmpty {
                forceQuit = leftovers.map { monitor.forceQuitPlan(after: $0.1, of: $0.0) }
                quitSummary = summary + " Force Quit ends them at once; they get no chance to clean up."
                isExecuting = false
                return
            }
            library.toast = Toast(message: summary + (action == .freeze ? " Resume lets them run again." : ""), undo: nil)
            dismiss()
        }
    }
}
