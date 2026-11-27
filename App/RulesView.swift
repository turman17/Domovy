import DomovyCore
import SwiftUI

/// Settings > Cleanup Rules: rules with on/off switches, when they run next, and every past
/// run with Undo. Rules tidy up on their own; this pane says exactly what they do and did.
struct RulesView: View {
    @Environment(RulesController.self) private var controller
    @Environment(SessionLibrary.self) private var library
    /// The pane's plain settings (the nightly hour), shown above the rules.
    let settingRows: AnyView
    @State private var editing: RuleEditRequest?
    @State private var deleting: CleanupRule?

    var body: some View {
        @Bindable var controller = controller
        Form {
            Section {
                header
                settingRows
            }
            if let pending = controller.pendingReview, !pending.isEmpty {
                Section {
                    reviewBanner(pending)
                }
            }
            Section("Rules") {
                ForEach(controller.rules) { rule in
                    RuleRow(rule: rule, lastRun: controller.lastRun(of: rule), onToggle: { on in
                        controller.setEnabled(rule, on)
                    }, menu: { menu(for: rule) })
                    .contextMenu { menu(for: rule) }
                }
                if controller.rules.isEmpty {
                    Text("No rules yet. Add one with the + button.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("History") {
                if controller.history.isEmpty {
                    Text("No runs yet. Each run is listed here with what it changed.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.history) { record in
                    RunRow(record: record, ruleTitles: titles(of: record), canUndo: controller.canUndo(record)) {
                        Task { await controller.undo(record) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup {
                Button("Run Now\u{2026}", systemImage: "play") {
                    controller.reviewRequest = RuleReviewRequest(rules: controller.enabledRules)
                }
                .disabled(!controller.hasEnabledRules || controller.isRunning)
                .help(!controller.hasEnabledRules ? "Turn on a rule to run it" : controller.isRunning ? "Rules are running" : "Preview what the rules that are on would do now, then run them")
                Button("New Rule", systemImage: "plus") {
                    editing = RuleEditRequest(rule: CleanupRule(action: .archive, condition: RuleCondition(idleDays: 30)), isNew: true)
                }
                .keyboardShortcut("n")
                .help("Add a rule")
            }
        }
        .sheet(item: $editing) { request in
            RulesEditorSheet(request: request)
        }
        .sheet(item: $controller.reviewRequest) { request in
            RulesPreviewSheet(request: request)
        }
        .confirmationDialog(
            "Delete the rule \u{201C}\(deleting?.title ?? "")\u{201D}?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete Rule", role: .destructive) {
                if let deleting { controller.remove(deleting) }
                deleting = nil
            }
        } message: {
            Text("Its past runs stay in the history and can still be undone.")
        }
        .alert("Rules", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.errorMessage = nil } })) {
            Button("OK") { controller.errorMessage = nil }
        } message: {
            Text(controller.errorMessage ?? "")
        }
        .onAppear { controller.refresh() }
        // ⌘Z or the toast may have undone a run; the history follows the undo log.
        .onChange(of: library.lastScan) { controller.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rules tidy up on their own once a night at \(controller.scheduledTimeText), or when you run them. They never touch live sessions or anything active in the last day, skip agents Domovy only reads, and every run can be undone.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Image(systemName: controller.hasEnabledRules ? "clock" : "moon.zzz")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(nextRunText)
                    .fontWeight(.medium)
                if controller.isRunning {
                    ProgressView().controlSize(.small)
                    Text("Running\u{2026}").foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var nextRunText: String {
        guard let next = controller.nextRun else { return "All rules are off. Turn one on to start." }
        let upcoming = controller.upcoming
        let what = upcoming.count == 0
            ? "nothing matches right now"
            : "about \(upcoming.count) \(upcoming.count == 1 ? "session" : "sessions") (\(upcoming.bytes.formatted(.byteCount(style: .file))))"
        return "Next run \(RulesController.describe(next)): \(what)."
    }

    private func reviewBanner(_ pending: RulePreview) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "hand.raised")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Waiting for your review").fontWeight(.semibold)
                Text(pending.summary.replacingOccurrences(of: " You can undo this.", with: "") + " Nothing changes until you confirm.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Review\u{2026}") { Task { await controller.review() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func menu(for rule: CleanupRule) -> some View {
        Button("Edit\u{2026}") { editing = RuleEditRequest(rule: rule, isNew: false) }
        Button("Preview\u{2026}") { controller.reviewRequest = RuleReviewRequest(rules: [rule], isPreviewOnly: !rule.isEnabled) }
        Button(rule.isEnabled ? "Turn Off" : "Turn On") { controller.setEnabled(rule, !rule.isEnabled) }
        Divider()
        Button("Delete Rule\u{2026}") { deleting = rule }
    }

    private func titles(of record: RuleRunRecord) -> [String] {
        record.ruleIDs.compactMap { id in controller.rules.first { $0.id == id }?.title }
    }
}

/// One rule: switch, the rule in words, its last run.
private struct RuleRow<Actions: View>: View {
    let rule: CleanupRule
    let lastRun: RuleRunRecord?
    let onToggle: @MainActor @Sendable (Bool) -> Void
    @ViewBuilder let menu: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle(rule.title, isOn: Binding(get: { rule.isEnabled }, set: onToggle))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .help(!rule.isEnabled ? "Off" : rule.askBeforeRunning ? "On: asks you every night before running" : "On: runs every night")
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.title)
                    .fontWeight(.medium)
                if rule.title != rule.sentence {
                    Text(rule.sentence)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if rule.askBeforeRunning {
                        Label("Asks first", systemImage: "hand.raised")
                    }
                    if let lastRun {
                        Text("Last run \(Text(lastRun.startedAt, format: .relative(presentation: .named))): \(lastRun.summary)")
                            .help(lastRun.startedAt.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never run")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                menu()
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Edit, preview or delete this rule")
            .accessibilityLabel("Actions for \(rule.title)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

/// One past run: what it did, when and why, sessions it left alone, Undo.
private struct RunRow: View {
    let record: RuleRunRecord
    let ruleTitles: [String]
    let canUndo: Bool
    let onUndo: () -> Void

    private var symbol: String {
        switch record.outcome {
        case .completed: record.undoneAt == nil ? "checkmark.circle" : "arrow.uturn.backward.circle"
        case .partial: "exclamationmark.circle"
        case .nothingToDo: "circle.dotted"
        case .skippedPower: "battery.25"
        case .awaitingReview: "hand.raised"
        case .failed: "xmark.circle"
        }
    }

    private var trigger: String {
        switch record.trigger {
        case .scheduled: "Nightly run"
        case .manual: "Run from Domovy"
        case .cli: "Run from domo"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.summary)
                HStack(spacing: 4) {
                    Text(trigger)
                    Text("\u{00B7}")
                    Text(record.startedAt, format: .relative(presentation: .named))
                        .help(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if record.undoneAt != nil {
                        Text("\u{00B7} Undone")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !ruleTitles.isEmpty {
                    Text(ruleTitles.joined(separator: "; "))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if !record.skipped.isEmpty || record.notes.count > 1 {
                    DisclosureGroup(record.skipped.isEmpty ? "Details" : "\(record.skipped.count) left alone") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(record.skipped.enumerated()), id: \.offset) { _, skip in
                                Text("\(skip.agent.displayName)\(skip.sessionID.map { " " + $0.prefix(8) } ?? ""): \(skip.reason)")
                                    .font(.system(.caption, design: .default))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                            ForEach(Array(record.notes.dropFirst().enumerated()), id: \.offset) { _, note in
                                Text(note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                }
            }
            Spacer()
            if canUndo {
                Button("Undo", action: onUndo)
                    .help("Put back everything this run changed")
            }
        }
        .padding(.vertical, 2)
    }
}

/// "Rules: next run tonight at 3:00, 12 sessions" in the menu bar popover, when a rule is on.
struct RulesMenuBarRow: View {
    @Environment(RulesController.self) private var controller
    let onOpen: () -> Void

    var body: some View {
        if let next = controller.nextRun {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "checklist")
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(text(next))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
    }

    private func text(_ next: Date) -> String {
        if controller.isRunning { return "Rules are running\u{2026}" }
        let count = controller.upcoming.count
        let what = count == 0 ? "" : ", \(count) \(count == 1 ? "session" : "sessions")"
        let review = controller.pendingReview.map { ". \($0.matches.count) waiting for review" } ?? ""
        return "Rules: next run \(RulesController.describe(next))\(what)\(review)"
    }
}

/// Opens Settings on Cleanup Rules when a notification asks for it (Review, or a tap on a run).
struct RulesWindowOpener: ViewModifier {
    let controller: RulesController
    @Environment(\.openSettings) private var openSettings

    func body(content: Content) -> some View {
        content.onChange(of: controller.wantsSettings) { _, wants in
            guard wants else { return }
            controller.wantsSettings = false
            AppSettings.shared.requestedPane = .rules
            openSettings()
            NSApp.activate()
        }
    }
}
