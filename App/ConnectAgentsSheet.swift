import AppKit
import DomovyCore
import SwiftUI

/// Registers Domovy's MCP server and skill with the agents on this Mac. One click: Set Up All
/// Agents installs the domo command in PATH when needed, registers the server and installs the
/// skill in every detected agent, then shows one summary. Details (one row per agent with the
/// exact command or file change, to copy and run by hand if preferred) stay collapsed.
struct ConnectAgentsSheet: View {
    /// What Set Up All Agents did, in one place.
    struct Summary {
        var connected: [ConnectAgent] = []
        var alreadyConnected: [ConnectAgent] = []
        var failed: [Failure] = []
        var command: String?
        var advice: [String] = []
    }

    struct Failure: Hashable {
        let agent: ConnectAgent
        let reason: String
    }

    @Environment(\.dismiss) private var dismiss
    @State private var plan: ConnectPlan?
    @State private var selected: Set<ConnectAgent> = []
    @State private var results: [ConnectAgent: AgentConnectResult.Outcome] = [:]
    @State private var isWorking = false
    @State private var link: DomoCommandLink.Status?
    @State private var domo: URL?
    @State private var summary: Summary?
    @State private var showsDetails = false
    /// Set when the sheet is the last page of onboarding: Back replaces Disconnect.
    var onBack: (() -> Void)? = nil

    static let terminalCommand = "domo install"

    private var connector: AgentConnector {
        AgentConnector(home: AppEnvironment.home, isCustomHome: AppEnvironment.isDevHome, storeRoot: AppEnvironment.storeRoot)
    }

    private var command: [String] {
        domo.map { MCPRegistration.serverCommand(domo: $0, home: AppEnvironment.home, isCustomHome: AppEnvironment.isDevHome) } ?? []
    }

    private var detected: [AgentConnectPlan] {
        plan?.agents.filter { $0.state != .notDetected } ?? []
    }

    private var manualScript: String {
        plan?.manualScript(home: AppEnvironment.home, agents: selected) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect your agents")
                    .font(.title3.weight(.semibold))
                Text("Domovy adds a small MCP server and a skill to each agent, so you can ask it to list and tidy sessions. The agent shows you a plan and asks before anything changes. Config files are backed up first, and Disconnect removes exactly what was added.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if plan == nil {
                ProgressView().frame(maxWidth: .infinity, minHeight: 80)
            } else if detected.isEmpty {
                Text("No agents found on this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                setUp
            }
            DisclosureGroup("Details", isExpanded: $showsDetails) {
                details
                    .padding(.top, 8)
            }
            HStack {
                if let onBack {
                    Button("Back", action: onBack)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Set Up All Agents") { setUpAll() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isWorking || detected.isEmpty || (domo == nil && DomoCommand.bundled == nil))
            }
        }
        .padding(24)
        .frame(width: 680)
        .task {
            await loadCommand()
            await refresh(selectingAll: true)
        }
    }

    /// The found agents before setup, the one summary after it.
    @ViewBuilder
    private var setUp: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary {
                summaryView(summary)
            } else {
                let names = detected.map(\.agent.displayName)
                Label("Found \(names.count) \(names.count == 1 ? "agent" : "agents"): \(ListFormatter.localizedString(byJoining: names)).", systemImage: "sparkles")
                    .fixedSize(horizontal: false, vertical: true)
                Text("Set Up All Agents installs the domo command if it is missing, adds Domovy's MCP server to each agent and installs the domovy skill. Already connected agents are left as they are.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryView(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let done = summary.connected.count + summary.alreadyConnected.count
            if done > 0 {
                Label(summary.connected.isEmpty
                      ? "All \(done) \(done == 1 ? "agent was" : "agents were") already connected."
                      : "Connected \(ListFormatter.localizedString(byJoining: summary.connected.map(\.displayName)))."
                        + (summary.alreadyConnected.isEmpty ? "" : " \(summary.alreadyConnected.count) already connected."),
                      systemImage: "checkmark.circle")
                    .foregroundStyle(.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(summary.failed, id: \.agent) { item in
                Label("\(item.agent.displayName): \(item.reason)", systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(([summary.command].compactMap { $0 } + summary.advice), id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Per-agent rows with checkboxes, the manual forms, Connect and Disconnect for the checked ones.
    @ViewBuilder
    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            commandStatus
            if !detected.isEmpty {
                List(detected) { item in
                    row(item)
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .frame(minHeight: 280)
            }
            terminalFallback
            HStack {
                if onBack == nil {
                    Button("Disconnect") { run(.disconnect) }
                        .disabled(isWorking || !detected.contains { selected.contains($0.agent) && $0.isConnected })
                }
                Button("Copy All Commands") { Self.copy(manualScript) }
                    .disabled(manualScript.isEmpty)
                    .help("Copies every change for the checked agents, as Terminal commands and config snippets")
                Spacer()
                Button("Connect Checked") { run(.connect) }
                    .disabled(isWorking || domo == nil || selected.isEmpty)
            }
        }
    }

    /// Which `domo` agents will run, and the Install button when it is not on PATH.
    @ViewBuilder
    private var commandStatus: some View {
        if link != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let domo {
                    Label {
                        Text("Agents will run \(DomovyTools.display(domo, home: AppEnvironment.home))")
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } icon: {
                        Image(systemName: "terminal")
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Label("This copy of Domovy has no domo command inside it. Install it with: brew install turman17/tap/domo", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .notInstalled = link {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Install the domo command in PATH to use it in Terminal too, and to give agents a path that stays put when Domovy moves.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Install \u{2018}domo\u{2019} Command\u{2026}") {
                            Task {
                                link = await DomoCommand.install()
                                await loadCommand()
                                await refresh(selectingAll: false)
                            }
                        }
                        .controlSize(.small)
                        .disabled(DomoCommand.bundled == nil)
                    }
                }
            }
        }
    }

    private var terminalFallback: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Prefer Terminal?")
                .foregroundStyle(.secondary)
            Text(Self.terminalCommand)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Button("Copy") { Self.copy(Self.terminalCommand) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Copy \(Self.terminalCommand)")
            Text("(pick agents in Terminal; --dry-run shows the plan)")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func row(_ item: AgentConnectPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: Binding(
                    get: { selected.contains(item.agent) },
                    set: { if $0 { selected.insert(item.agent) } else { selected.remove(item.agent) } }
                )) {
                    Text(item.agent.displayName)
                }
                .toggleStyle(.checkbox)
                Spacer()
                status(item)
            }
            Group {
                if let reason = problem(item) {
                    note(reason)
                } else {
                    if item.state == .willChange {
                        let manual = item.manualSteps(home: AppEnvironment.home, domo: command.first)
                        ForEach(Array(zip(item.steps, manual).enumerated()), id: \.offset) { _, pair in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(pair.0.description(home: AppEnvironment.home))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Copy", systemImage: "doc.on.doc") { Self.copy(pair.1.text) }
                                    .labelStyle(.iconOnly)
                                    .buttonStyle(.borderless)
                                    .help(pair.1.isShellCommand ? "Copies the Terminal command" : "Copies the text to add to the file")
                                    .accessibilityLabel("Copy: \(pair.1.title)")
                            }
                        }
                        DisclosureGroup("Do it by hand") {
                            ForEach(Array(manual.enumerated()), id: \.offset) { _, step in
                                self.manual(step)
                            }
                        }
                        .font(.callout)
                    }
                    ForEach(item.notes, id: \.self) { note($0) }
                }
            }
            .padding(.leading, 20)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func manual(_ step: ManualStep) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(step.isShellCommand ? "\(step.title), in Terminal:" : "\(step.title):")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 6) {
                Text(step.text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                Button("Copy", systemImage: "doc.on.doc") { Self.copy(step.text) }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy: \(step.title)")
            }
        }
    }

    @ViewBuilder
    private func status(_ item: AgentConnectPlan) -> some View {
        if case .failed(let reason) = results[item.agent] {
            Label("Failed", systemImage: "exclamationmark.triangle")
                .help(reason)
                .accessibilityLabel("Failed: \(reason)")
        } else if case .refused(let reason) = item.state {
            Label("Can\u{2019}t connect now", systemImage: "pause.circle")
                .help(reason)
                .accessibilityLabel("Can't connect now: \(reason)")
        } else if item.isConnected {
            Label("Connected", systemImage: "checkmark.circle")
                .foregroundStyle(.tint)
        } else {
            Label("Not connected", systemImage: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }

    private func problem(_ item: AgentConnectPlan) -> String? {
        if case .failed(let reason) = results[item.agent] { return reason }
        if case .refused(let reason) = item.state { return reason }
        return nil
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func loadCommand() async {
        let status = await DomoCommand.status()
        link = status
        domo = DomoCommand.registered(status)
    }

    private func refresh(selectingAll: Bool) async {
        let connector = connector, command = command
        let fresh = await Task.detached { connector.plan(.connect, command: command) }.value
        plan = fresh
        if selectingAll {
            selected = Set(fresh.agents.filter { $0.state != .notDetected }.map(\.agent))
        }
    }

    /// Everything in one go: the domo link if missing, then every detected agent.
    private func setUpAll() {
        isWorking = true
        Task {
            var summary = Summary()
            if case .notInstalled = link, let bundled = DomoCommand.bundled {
                let outcome: Result<DomoCommandLink.Target, any Error> = await Task.detached {
                    Result { try DomoCommand.link().install(bundled: bundled) }
                }.value
                switch outcome {
                case .success(let target):
                    summary.advice.append("Installed the domo command at \(DomovyTools.display(target.link, home: AppEnvironment.home)).")
                    if let advice = target.pathAdvice {
                        summary.advice.append("That folder is not on your PATH yet; for Terminal, add this line to ~/.zshrc: \(advice)")
                    }
                case .failure(let error):
                    // Agents still get the domo inside Domovy.app.
                    summary.advice.append("The domo command was not installed in PATH: \((error as? DomoCommandLink.LinkError)?.message ?? error.localizedDescription)")
                }
                await loadCommand()
            }
            let connector = connector, command = command
            if let domo { summary.command = "Agents run \(DomovyTools.display(domo, home: AppEnvironment.home))." }
            let planned = await Task.detached { connector.plan(.connect, command: command) }.value
            let outcomes = await Task.detached { connector.execute(planned) }.value
            for item in planned.agents where item.state != .notDetected {
                let outcome = outcomes.first { $0.agent == item.agent }?.outcome
                results[item.agent] = outcome
                switch (item.state, outcome) {
                case (_, .failed(let reason)?): summary.failed.append(Failure(agent: item.agent, reason: reason))
                case (.upToDate, _): summary.alreadyConnected.append(item.agent)
                case (.willChange, .changed?):
                    summary.connected.append(item.agent)
                    if !summary.advice.contains(item.agent.reloadAdvice) { summary.advice.append(item.agent.reloadAdvice) }
                default: break
                }
            }
            self.summary = summary
            await refresh(selectingAll: false)
            isWorking = false
        }
    }

    private func run(_ mode: ConnectPlan.Mode) {
        isWorking = true
        let connector = connector, command = command, agents = Array(selected)
        Task {
            let outcomes = await Task.detached {
                connector.execute(connector.plan(mode, command: command, agents: agents))
            }.value
            for result in outcomes { results[result.agent] = result.outcome }
            await refresh(selectingAll: false)
            isWorking = false
        }
    }
}
