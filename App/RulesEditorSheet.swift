import DomovyCore
import SwiftUI

/// A rule to edit, or a new one.
struct RuleEditRequest: Identifiable {
    let id = UUID()
    let rule: CleanupRule
    let isNew: Bool
}

/// Builds a rule as a sentence: "[Archive] [Codex] sessions idle for [30] days". The full
/// sentence and what the action does are spelled out below the controls; Preview shows what
/// the rule would do right now, without changing anything.
struct RulesEditorSheet: View {
    let request: RuleEditRequest

    @Environment(RulesController.self) private var controller
    @Environment(SessionLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var action: RuleAction = .archive
    @State private var agents: Set<AgentKind> = []
    @State private var project = ""
    @State private var status: Session.Status?
    @State private var idleOn = true
    @State private var idleDays = 30
    @State private var sizeOn = false
    @State private var sizeMB = 50
    @State private var archivedOn = false
    @State private var archivedDays = 60
    @State private var expiringOn = false
    @State private var expiringDays = 7
    @State private var name = ""
    @State private var askFirst = false
    @State private var isEnabled = false
    @State private var previewing: RuleReviewRequest?
    @State private var didLoad = false

    private var built: CleanupRule {
        var rule = request.rule
        rule.action = action
        rule.scope.agents = AgentKind.allCases.filter { agents.contains($0) }
        let trimmed = project.trimmingCharacters(in: .whitespaces)
        rule.scope.projects = trimmed.isEmpty ? [] : [trimmed]
        rule.scope.statuses = status.map { [$0] } ?? []
        rule.condition = RuleCondition(
            idleDays: idleOn ? idleDays : nil,
            minimumBytes: sizeOn ? Int64(sizeMB) * 1_000_000 : nil,
            archivedDays: archivedOn && action != .archive ? archivedDays : nil,
            expiresWithinDays: expiringOn ? expiringDays : nil
        )
        let typed = name.trimmingCharacters(in: .whitespaces)
        // A preset's name stays only while the rule still says what the preset said.
        if request.rule.presetID != nil, rule.condition != request.rule.condition || rule.scope != request.rule.scope || rule.action != request.rule.action,
           typed == request.rule.name {
            rule.name = nil
        } else {
            rule.name = typed.isEmpty ? nil : typed
        }
        rule.askBeforeRunning = askFirst
        rule.isEnabled = isEnabled
        return rule
    }

    /// Agents to offer: the ones with sessions here, plus any the rule already names.
    private var agentChoices: [AgentKind] {
        let present = Set(library.agentsPresent).union(request.rule.scope.agents)
        return AgentKind.allCases.filter { present.contains($0) && $0.hasSessions }
    }

    private var agentLabel: String {
        let chosen = AgentKind.allCases.filter { agents.contains($0) }
        switch chosen.count {
        case 0: return "All agents"
        case 1: return chosen[0].displayName
        default: return "\(chosen.count) agents"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.isNew ? "New Rule" : "Edit Rule")
                .font(.title3.weight(.semibold))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Picker("Action", selection: $action) {
                        Text("Archive").tag(RuleAction.archive)
                        Text("Move to the Trash").tag(RuleAction.moveToTrash)
                        Text("Move to quarantine").tag(RuleAction.moveToQuarantine)
                    }
                    .labelsHidden()
                    .fixedSize()
                    agentMenu
                    Picker("Status", selection: $status) {
                        Text("sessions").tag(Session.Status?.none)
                        Text("idle sessions").tag(Session.Status?.some(.idle))
                        Text("expiring sessions").tag(Session.Status?.some(.expiring))
                        if action != .archive {
                            Text("archived sessions").tag(Session.Status?.some(.archived))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                condition("idle for", isOn: $idleOn, value: $idleDays, unit: "days", range: 1...3_650)
                condition("larger than", isOn: $sizeOn, value: $sizeMB, unit: "MB", range: 1...1_000_000)
                if action != .archive {
                    condition("archived for", isOn: $archivedOn, value: $archivedDays, unit: "days", range: 1...3_650)
                }
                condition("due to be deleted by the agent within", isOn: $expiringOn, value: $expiringDays, unit: "days", range: 0...365)
                HStack(spacing: 6) {
                    Text("in projects containing")
                    TextField("any project", text: $project)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                .padding(.leading, 24)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(built.sentence + ".")
                        .fontWeight(.medium)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(built.actionExplanation + " Live sessions and sessions active in the last day are always left alone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let problem = built.validationProblem {
                        Label(problem, systemImage: "exclamationmark.circle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            Form {
                TextField("Name", text: $name, prompt: Text("Optional"))
                Toggle("Ask before running", isOn: $askFirst)
                    .help("The nightly run sends a notification with the plan instead of acting. Nothing changes until you confirm.")
                Toggle("Turn on", isOn: $isEnabled)
                    .help("Rules that are on run every night at \(controller.scheduledTimeText).")
            }

            HStack {
                Button("Preview\u{2026}") {
                    previewing = RuleReviewRequest(rules: [built], isPreviewOnly: true)
                }
                .disabled(built.validationProblem != nil)
                .help(built.validationProblem ?? "Show what this rule would do right now. Nothing changes.")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(request.isNew ? "Add Rule" : "Save") {
                    controller.save(built)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(built.validationProblem != nil)
                .help(built.validationProblem ?? "")
            }
        }
        .padding(20)
        .frame(width: 560)
        .sheet(item: $previewing) { request in
            RulesPreviewSheet(request: request)
        }
        .onAppear(perform: load)
    }

    private var agentMenu: some View {
        Menu(agentLabel) {
            Button {
                agents = []
            } label: {
                if agents.isEmpty { Label("All agents", systemImage: "checkmark") } else { Text("All agents") }
            }
            Divider()
            ForEach(agentChoices, id: \.self) { agent in
                Button {
                    if agents.contains(agent) { agents.remove(agent) } else { agents.insert(agent) }
                } label: {
                    if agents.contains(agent) { Label(agent.displayName, systemImage: "checkmark") } else { Text(agent.displayName) }
                }
            }
        }
        .fixedSize()
        .accessibilityLabel("Agents: \(agentLabel)")
    }

    private func condition(_ text: String, isOn: Binding<Bool>, value: Binding<Int>, unit: String, range: ClosedRange<Int>) -> some View {
        HStack(spacing: 6) {
            Toggle(text, isOn: isOn)
            TextField(text, value: value, format: .number)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .disabled(!isOn.wrappedValue)
            Stepper(text, value: value, in: range)
                .labelsHidden()
                .disabled(!isOn.wrappedValue)
            Text(value.wrappedValue == 1 && unit == "days" ? "day" : unit)
                .foregroundStyle(isOn.wrappedValue ? .primary : .secondary)
        }
    }

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        let rule = request.rule
        action = rule.action
        agents = Set(rule.scope.agents)
        project = rule.scope.projects.first ?? ""
        status = rule.scope.statuses.first
        idleOn = rule.condition.idleDays != nil
        idleDays = rule.condition.idleDays ?? 30
        sizeOn = rule.condition.minimumBytes != nil
        sizeMB = Int((rule.condition.minimumBytes ?? 50_000_000) / 1_000_000)
        archivedOn = rule.condition.archivedDays != nil
        archivedDays = rule.condition.archivedDays ?? 60
        expiringOn = rule.condition.expiresWithinDays != nil
        expiringDays = rule.condition.expiresWithinDays ?? 7
        name = rule.name ?? ""
        askFirst = rule.askBeforeRunning
        isEnabled = rule.isEnabled
    }
}
