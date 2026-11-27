import AppKit
import DomovyCore
import Observation
import ServiceManagement
import SwiftUI

/// Every setting of the Settings window, in display order. Each one changes real behaviour;
/// the ones stored in `settings.json` name their key.
@MainActor
enum SettingsCatalog {
    struct Section {
        let title: String
        let footer: String?
        let items: [SettingItem]
    }

    /// A category's items in sections, in the order they were declared.
    static func sections(_ category: SettingsCategory, items: [SettingItem]) -> [Section] {
        var order: [String] = []
        var grouped: [String: [SettingItem]] = [:]
        for item in items where item.category == category {
            if grouped[item.group] == nil { order.append(item.group) }
            grouped[item.group, default: []].append(item)
        }
        return order.map { Section(title: $0, footer: footers[category.rawValue + "/" + $0], items: grouped[$0] ?? []) }
    }

    private static let footers: [String: String] = [
        "privacy/": "Domovy makes no network connections and sends no telemetry or analytics. Transcripts are read only to show and search them on this Mac; their content is never logged or sent anywhere.",
        "agents/Coding agents": "A hidden agent is left out of every list, scan, rule and disk total, in the app, domo and the MCP server. Its files are not touched.",
        "advanced/": "Settings live in settings.json in Domovy's folder, shared with domo and the MCP server. Edit it by hand if you like; Domovy reads it again when it becomes active.",
    ]

    static func items() -> [SettingItem] {
        general + sessions + safety + agents + search + rules + connect + privacy + advanced
    }

    // MARK: General

    private static var general: [SettingItem] {
        [
            SettingItem(id: "menuBar.display", category: .general, title: "Menu bar item",
                        detail: "What Domovy shows in the menu bar next to its icon, or hide it. Hidden, Domovy keeps its Dock icon.",
                        group: "Menu bar", keywords: ["icon", "status", "size", "live", "hide"], key: .menuBarDisplay,
                        control: AnyView(MenuBarDisplayPicker())),
            SettingItem(id: "menuBar.popover.breakdown", category: .general, title: "Show breakdown by agent",
                        detail: "The bar and list of disk use per agent in the menu bar popover.",
                        group: "Menu bar", keywords: ["popover"], key: .popoverShowsBreakdown,
                        control: AnyView(SettingToggle(\.popoverShowsBreakdown, title: "Show breakdown by agent"))),
            SettingItem(id: "menuBar.popover.attention", category: .general, title: "Show what needs attention",
                        detail: "Expiring sessions, live sessions, orphaned processes and large caches in the popover.",
                        group: "Menu bar", keywords: ["popover", "warnings", "expiring"], key: .popoverShowsAttention,
                        control: AnyView(SettingToggle(\.popoverShowsAttention, title: "Show what needs attention"))),
            SettingItem(id: "menuBar.popover.rules", category: .general, title: "Show the next rules run",
                        detail: "One line in the popover with when the cleanup rules run next.",
                        group: "Menu bar", keywords: ["popover", "schedule"], key: .popoverShowsRules,
                        control: AnyView(SettingToggle(\.popoverShowsRules, title: "Show the next rules run"))),
            SettingItem(id: "app.showInDock", category: .general, title: "Show in Dock",
                        detail: "Off: Domovy lives in the menu bar only. Stays on while the menu bar item is hidden.",
                        group: "App", keywords: ["dock", "menu bar only", "accessory"], key: .showsInDock,
                        control: AnyView(DockToggle())),
            SettingItem(id: "app.launchAtLogin", category: .general, title: "Open at login",
                        detail: "Starts Domovy when you log in, so the menu bar item and the nightly rules are always there.",
                        group: "App", keywords: ["startup", "login item", "launch"],
                        control: AnyView(LaunchAtLoginToggle())),
            SettingItem(id: "app.launchSection", category: .general, title: "Open the window on",
                        detail: "The section the main window shows when Domovy starts.",
                        group: "App", keywords: ["start", "launch", "section"], key: .launchSection,
                        control: AnyView(LaunchSectionPicker())),
            SettingItem(id: "app.welcome", category: .general, title: "Welcome screen",
                        detail: "Shows the introduction again: what Domovy reads and what it never does.",
                        group: "App", keywords: ["onboarding", "intro"],
                        control: AnyView(WelcomeButton())),
            SettingItem(id: "app.tour", category: .general, title: "Tour",
                        detail: "Walks through the main window with your own numbers: what the agents keep, and where to tidy.",
                        group: "App", keywords: ["tour", "walkthrough", "guide", "help"],
                        control: AnyView(Button("Take the Tour") { TakeTour.start() })),
        ]
    }

    // MARK: Sessions

    private static var sessions: [SettingItem] {
        [
            SettingItem(id: "sessions.defaultSort", category: .sessions, title: "Sort sessions by",
                        detail: "The list's order when Domovy opens. Clicking a column header sorts until you quit.",
                        keywords: ["order", "sort"], key: .defaultSort, control: AnyView(SortPicker())),
            SettingItem(id: "sessions.layout", category: .sessions, title: "Show sessions as",
                        detail: "One list, or grouped by project folder. The toolbar switch changes this too.",
                        keywords: ["projects", "group", "view"], key: .sessionsLayout, control: AnyView(LayoutPicker())),
            SettingItem(id: "sessions.hiddenColumns", category: .sessions, title: "Columns",
                        detail: "Which columns the list shows. Right-clicking the header changes this too.",
                        keywords: ["tokens", "cost", "project", "size", "status", "agent", "table"], key: .hiddenColumns,
                        layout: .stacked, control: AnyView(ColumnToggles())),
            SettingItem(id: "sessions.expiringWarningDays", category: .sessions, title: "Warn before agent cleanup",
                        detail: "Claude Code and Gemini CLI sessions this close to their agent's own deletion show as Expiring, with a banner and Archive all.",
                        keywords: ["retention", "expiring", "days", "banner"], key: .expiringWindowDays,
                        control: AnyView(ExpiringDaysStepper())),
        ]
    }

    // MARK: Safety

    private static var safety: [SettingItem] {
        [
            SettingItem(id: "safety.deleteDestination", category: .safety, title: "Removed files go to",
                        detail: "Where delete sheets start, and where domo rm, domo clean and the MCP server send files without --to. Sessions the secret scan flagged start on the quarantine.",
                        keywords: ["trash", "quarantine", "delete", "destination"], key: .deleteDestination,
                        control: AnyView(DestinationPicker())),
            SettingItem(id: "safety.quarantine", category: .safety, title: "Quarantine folder",
                        detail: "Inside Domovy's folder, so undo and purge always find it. Files stay until you purge them on the Disk screen.",
                        keywords: ["location", "path", "folder"],
                        layout: .stacked, control: AnyView(PathRow(url: AppEnvironment.storeRoot.appendingPathComponent("Quarantine", isDirectory: true)))),
            SettingItem(id: "safety.undo", category: .safety, title: "Undo history",
                        detail: "Every change Domovy made, kept until you purge it. Domovy never prunes it on its own; ⌘Z and domo undo use it.",
                        keywords: ["undo", "log", "history"], layout: .stacked, control: AnyView(UndoHistoryRow())),
            SettingItem(id: "safety.retentionRules", category: .safety, title: "Archive before agents delete",
                        detail: "Claude Code and Gemini CLI delete old sessions on their own. A cleanup rule can archive them first.",
                        keywords: ["retention", "sweep", "rules", "archive"], control: AnyView(OpenRulesButton())),
        ]
    }

    // MARK: Agents

    private static var agents: [SettingItem] {
        let coding = AgentKind.allCases.filter(\.hasSessions)
        let measured = AgentKind.allCases.filter { !$0.hasSessions && !$0.isModelStore }
        let models = AgentKind.allCases.filter(\.isModelStore)
        func row(_ kind: AgentKind, group: String) -> SettingItem {
            SettingItem(id: "agents.hidden." + kind.rawValue, category: .agents, title: kind.displayName,
                        detail: kind.isExperimental ? AgentStatuses.summary(kind) + " " + AgentKind.experimentalNote : AgentStatuses.summary(kind),
                        group: group, keywords: ["hide", "show", "agent", kind.rawValue] + (kind.isExperimental ? ["experimental"] : []),
                        isModified: { $0.isHidden(kind) },
                        reset: { settings in settings.update { $0.hiddenAgents.remove(kind) } },
                        control: AnyView(AgentRowControl(kind: kind)))
        }
        return coding.map { row($0, group: "Coding agents") }
            + [SettingItem(id: "agents.aider.searchFolders", category: .agents, title: "Aider search folders",
                           detail: "Aider keeps no index. Besides the projects other agents know, Domovy looks in these folders and one level below them.",
                           group: "Aider", keywords: ["aider", "folders", "roots", "paths"], key: .aiderSearchFolders,
                           layout: .stacked, control: AnyView(AiderFoldersEditor()))]
            + measured.map { row($0, group: "Measured on the Disk screen") }
            + models.map { row($0, group: "Local model stores") }
    }

    // MARK: Search

    private static var search: [SettingItem] {
        [
            SettingItem(id: "search.transcriptIndex", category: .search, title: "Search inside transcripts",
                        detail: "Lets the toolbar search look through everything said in sessions, using an index kept on this Mac. Off, transcripts are never indexed.",
                        keywords: ["full text", "index", "fts"], key: .transcriptIndex,
                        control: AnyView(SettingToggle(\.transcriptIndex, title: "Search inside transcripts"))),
            SettingItem(id: "search.index", category: .search, title: "Search index",
                        detail: "Words from transcripts, in Domovy's folder only. Clearing it deletes them; it is built again at the next transcript search.",
                        keywords: ["rebuild", "clear", "size", "location"], layout: .stacked, control: AnyView(SearchIndexRow())),
        ]
    }

    // MARK: Rules

    private static var rules: [SettingItem] {
        [
            SettingItem(id: "rules.nightlyHour", category: .rules, title: "Nightly run at",
                        detail: "When the rules that are on run each day. A Mac asleep then runs them at the next check after.",
                        keywords: ["schedule", "time", "hour"], key: .nightlyHour, control: AnyView(NightlyHourPicker())),
        ]
    }

    private static let ruleItemPrefix = "rules.rule."

    /// One search entry per rule, so "codex" or "archive" finds the rules that match.
    static func ruleItems(_ rules: [CleanupRule]) -> [SettingItem] {
        rules.map { rule in
            SettingItem(id: ruleItemPrefix + rule.id.uuidString, category: .rules, title: rule.title,
                        detail: rule.sentence, group: "Rules", keywords: ["rule", "cleanup", "automatic"],
                        isModified: { _ in false }, control: AnyView(RuleSwitch(id: rule.id)))
        }
    }

    static func isRuleItem(_ item: SettingItem) -> Bool { item.id.hasPrefix(ruleItemPrefix) }

    // MARK: Connect

    private static var connect: [SettingItem] {
        [
            SettingItem(id: "connect.agents", category: .connect, title: "Agents connected to Domovy",
                        detail: "Domovy's MCP server and skill let an agent list and tidy sessions, always with a plan you confirm.",
                        keywords: ["mcp", "skill", "connect"], control: AnyView(ConnectRow())),
            SettingItem(id: "connect.cli", category: .connect, title: "\u{2018}domo\u{2019} command in PATH",
                        detail: "Links the domo inside Domovy into a folder on your PATH, so Terminal and agents can run it. Uninstall removes only that link.",
                        keywords: ["cli", "terminal", "path", "domo", "install"], control: AnyView(DomoCommandControls())),
        ]
    }

    // MARK: Privacy

    private static var privacy: [SettingItem] {
        [
            SettingItem(id: "privacy.fullDiskAccess", category: .privacy, title: "Full Disk Access",
                        detail: "Optional. A few agents keep data in folders macOS protects; with access, Domovy can measure them too.",
                        keywords: ["permission", "tcc", "privacy"], control: AnyView(FullDiskAccessRow())),
        ]
    }

    // MARK: Advanced

    private static var advanced: [SettingItem] {
        [
            SettingItem(id: "advanced.dataFolder", category: .advanced, title: "Domovy's folder",
                        detail: "Quarantine, undo history, rules, search index and settings.",
                        keywords: ["store", "data", "location"], layout: .stacked, control: AnyView(PathRow(url: AppEnvironment.storeRoot))),
            SettingItem(id: "advanced.settingsFile", category: .advanced, title: "settings.json",
                        detail: "The same settings as a file, for editing by hand or syncing.",
                        keywords: ["json", "file", "edit"], layout: .stacked, control: AnyView(SettingsFileRow())),
            SettingItem(id: "advanced.resetAll", category: .advanced, title: "Reset all settings",
                        detail: "Puts every setting back to its default. Your sessions, rules and undo history stay.",
                        keywords: ["defaults", "reset"], control: AnyView(ResetAllButton())),
        ]
    }
}

// MARK: - Controls

/// A switch for one Boolean setting.
private struct SettingToggle: View {
    @Environment(AppSettings.self) private var settings
    let keyPath: WritableKeyPath<DomovySettings, Bool>
    /// The row's title, for VoiceOver: the label is hidden beside the row's own.
    let title: String

    init(_ keyPath: WritableKeyPath<DomovySettings, Bool>, title: String) {
        self.keyPath = keyPath
        self.title = title
    }

    var body: some View {
        Toggle(title, isOn: settings.binding(keyPath))
            .labelsHidden()
            .toggleStyle(.switch)
    }
}

private struct MenuBarDisplayPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Picker("Menu bar item", selection: settings.binding(\.menuBarDisplay)) {
            Text("Icon only").tag(DomovySettings.MenuBarDisplay.iconOnly)
            Text("Icon and total size").tag(DomovySettings.MenuBarDisplay.totalSize)
            Text("Icon and safe-to-remove size").tag(DomovySettings.MenuBarDisplay.reclaimableSize)
            Text("Icon and live sessions").tag(DomovySettings.MenuBarDisplay.liveSessions)
            Divider()
            Text("Hidden").tag(DomovySettings.MenuBarDisplay.hidden)
        }
        .labelsHidden()
        .fixedSize()
    }
}

private struct DockToggle: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let menuBarShown = settings.settings.showsMenuBarItem
        Toggle("Show in Dock", isOn: Binding(
            get: { settings.settings.effectiveShowsInDock },
            set: { on in settings.update { $0.showsInDock = on } }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .disabled(!menuBarShown)
        .help(menuBarShown ? "" : "Show the menu bar item first, so Domovy stays reachable.")
    }
}

/// The login item is macOS's to keep, not the settings file's.
private struct LaunchAtLoginToggle: View {
    @State private var isOn = AppPresence.opensAtLogin
    @State private var needsApproval = AppPresence.loginItemNeedsApproval
    @State private var error: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Toggle("Open at login", isOn: Binding(get: { isOn }, set: { set($0) }))
                .labelsHidden()
                .toggleStyle(.switch)
            if needsApproval {
                Button("Allow in Login Items\u{2026}") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func set(_ on: Bool) {
        do {
            try AppPresence.setOpensAtLogin(on)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isOn = AppPresence.opensAtLogin
        needsApproval = AppPresence.loginItemNeedsApproval
    }
}

private struct LaunchSectionPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Picker("Open the window on", selection: settings.binding(\.launchSection)) {
            ForEach(DomovySettings.LaunchSection.allCases, id: \.self) { section in
                Label(SidebarItem(section).rawValue, systemImage: SidebarItem(section).symbol).tag(section)
            }
        }
        .labelsHidden()
        .fixedSize()
    }
}

private struct WelcomeButton: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Button("Welcome to Domovy\u{2026}") {
            MainWindow.open()
            settings.wantsOnboarding = true
        }
    }
}

private struct SortPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Picker("Sort sessions by", selection: settings.binding(\.defaultSort)) {
            Text("Last active, newest first").tag(DomovySettings.SessionSort.lastActive)
            Text("Size, largest first").tag(DomovySettings.SessionSort.size)
            Text("Title").tag(DomovySettings.SessionSort.title)
            Text("Agent").tag(DomovySettings.SessionSort.agent)
            Text("Project").tag(DomovySettings.SessionSort.project)
            Text("Status").tag(DomovySettings.SessionSort.status)
        }
        .labelsHidden()
        .fixedSize()
    }
}

private struct LayoutPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Picker("Show sessions as", selection: settings.binding(\.sessionsLayout)) {
            Text("List").tag(SessionsLayout.list)
            Text("By Project").tag(SessionsLayout.projects)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

private struct ColumnToggles: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(SessionColumn.optional, id: \.id) { column in
                Toggle(column.title, isOn: Binding(
                    get: { !settings.settings.hiddenColumns.contains(column.id) },
                    set: { shown in
                        settings.update { settings in
                            var hidden = Set(settings.hiddenColumns)
                            if shown { hidden.remove(column.id) } else { hidden.insert(column.id) }
                            settings.hiddenColumns = SessionColumn.optional.map(\.id).filter(hidden.contains)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
            }
        }
    }
}

private struct ExpiringDaysStepper: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        let days = settings.settings.expiringWindowDays
        Stepper(value: settings.binding(\.expiringWindowDays), in: DomovySettings.expiringWindowRange) {
            Text("\(days) \(days == 1 ? "day" : "days") before")
                .monospacedDigit()
        }
        .fixedSize()
    }
}

private struct DestinationPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Picker("Removed files go to", selection: settings.binding(\.deleteDestination)) {
            Label("Trash", systemImage: "trash").tag(Destination.trash)
            Label("Domovy quarantine", systemImage: "archivebox").tag(Destination.quarantine)
        }
        .labelsHidden()
        .fixedSize()
    }
}

/// A folder's path in SF Mono, with Reveal in Finder.
private struct PathRow: View {
    let url: URL

    var body: some View {
        HStack(spacing: 8) {
            Text(PathText.abbreviated(url))
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(url.path)
            Spacer()
            Button("Reveal in Finder") { PathText.reveal(url) }
        }
    }
}

enum PathText {
    /// `~/Library/…` for paths in the home folder.
    static func abbreviated(_ url: URL) -> String {
        let home = AppEnvironment.home.path
        let path = url.path
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Opens the folder in the Finder, or its nearest existing parent.
    static func reveal(_ url: URL) {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

private struct UndoHistoryRow: View {
    @Environment(SessionLibrary.self) private var library
    @State private var count: Int?

    var body: some View {
        HStack(spacing: 8) {
            Text(count.map { "\($0) \($0 == 1 ? "change" : "changes") recorded" } ?? "Counting\u{2026}")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reveal in Finder") { PathText.reveal(library.executor.storeRoot.appendingPathComponent("Undo", isDirectory: true)) }
        }
        .task(id: library.lastScan) {
            let executor = library.executor
            count = await Task.detached { (try? executor.undoLog.entries().count) ?? 0 }.value
        }
    }
}

private struct OpenRulesButton: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RulesController.self) private var rules

    var body: some View {
        HStack(spacing: 8) {
            let on = rules.enabledRules.count
            Text(on == 0 ? "None on" : "\(on) on")
                .foregroundStyle(.secondary)
            Button("Show Rules") { settings.requestedPane = .rules }
        }
    }
}

/// A rule's on/off switch in search results.
private struct RuleSwitch: View {
    @Environment(RulesController.self) private var controller
    let id: CleanupRule.ID

    var body: some View {
        if let rule = controller.rules.first(where: { $0.id == id }) {
            Toggle(rule.title, isOn: Binding(get: { rule.isEnabled }, set: { controller.setEnabled(rule, $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// Show/hide switch and what Domovy found for one agent.
private struct AgentRowControl: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionLibrary.self) private var library
    @Environment(AgentStatuses.self) private var statuses
    let kind: AgentKind

    var body: some View {
        HStack(spacing: 8) {
            if kind.isExperimental { ExperimentalBadge() }
            let status = statuses.status(kind, footprints: library.footprints, hidden: settings.settings.isHidden(kind))
            Label(status.text, systemImage: status.symbol)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(status.help ?? status.text)
            Toggle("Show", isOn: Binding(
                get: { !settings.settings.isHidden(kind) },
                set: { shown in settings.update { if shown { $0.hiddenAgents.remove(kind) } else { $0.hiddenAgents.insert(kind) } } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .accessibilityLabel("Show \(kind.displayName)")
        }
    }
}

/// What each session agent's adapter reports (installed, not found, read-only and why), read
/// once per Settings window, with every agent included, hidden or not.
@MainActor
@Observable
final class AgentStatuses {
    private(set) var statuses: [AgentKind: AdapterStatus] = [:]
    private var loaded = false

    struct Display {
        let text: String
        let symbol: String
        var help: String?
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        let adapters = DomovyContext.standardAdapters(home: AppEnvironment.home, isCustomHome: AppEnvironment.isDevHome)
        let found = await Task.detached {
            await withTaskGroup(of: (AgentKind, AdapterStatus).self) { group in
                for adapter in adapters { group.addTask { (adapter.kind, await adapter.status()) } }
                var result: [AgentKind: AdapterStatus] = [:]
                for await (kind, status) in group { result[kind] = status }
                return result
            }
        }.value
        statuses = found
    }

    func status(_ kind: AgentKind, footprints: [Footprint], hidden: Bool) -> Display {
        if kind.hasSessions {
            switch statuses[kind] {
            case nil: return Display(text: "Checking\u{2026}", symbol: "ellipsis.circle")
            case .notInstalled: return Display(text: "Not found", symbol: "minus.circle")
            case .ready: return Display(text: hidden ? "Installed, hidden" : "Installed", symbol: "checkmark.circle")
            case .readOnly(let reason): return Display(text: "Read-only", symbol: "lock", help: reason)
            }
        }
        if hidden { return Display(text: "Hidden", symbol: "eye.slash") }
        return footprints.contains { $0.agent == kind }
            ? Display(text: "Found", symbol: "checkmark.circle")
            : Display(text: "Not found", symbol: "minus.circle")
    }

    /// One line per agent kind for its row.
    static func summary(_ kind: AgentKind) -> String {
        if kind.isModelStore { return "Downloaded models, measured and cleaned on the Disk screen." }
        if kind == .claudeDesktop { return "Its sessions are Claude Code's; Domovy measures its own folders on the Disk screen." }
        if kind.isFootprintOnly { return "Measured on the Disk screen; its sessions are not listed." }
        return "Sessions listed, archived and removed by Domovy."
    }
}

private struct AiderFoldersEditor: View {
    @Environment(AppSettings.self) private var settings
    @State private var selection: String?

    var body: some View {
        let folders = settings.settings.aiderSearchFolders
        VStack(alignment: .leading, spacing: 0) {
            List(selection: $selection) {
                ForEach(folders, id: \.self) { folder in
                    Text(folder)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .tag(folder)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 72, maxHeight: 140)
            .overlay {
                if folders.isEmpty {
                    Text("No folders. Domovy looks only in projects other agents know.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDeleteCommand(perform: remove)
            HStack(spacing: 0) {
                Button { add() } label: { Image(systemName: "plus").frame(width: 20, height: 18) }
                    .help("Add a folder")
                    .accessibilityLabel("Add folder")
                Button { remove() } label: { Image(systemName: "minus").frame(width: 20, height: 18) }
                    .help("Remove the selected folder")
                    .accessibilityLabel("Remove folder")
                    .disabled(selection == nil)
            }
            .buttonStyle(.borderless)
            .padding(.top, 4)
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose folders that hold your Aider projects."
        guard panel.runModal() == .OK else { return }
        let added = panel.urls.map { PathText.abbreviated($0) }
        settings.update { settings in
            for path in added where !settings.aiderSearchFolders.contains(path) { settings.aiderSearchFolders.append(path) }
        }
    }

    private func remove() {
        guard let selection else { return }
        settings.update { $0.aiderSearchFolders.removeAll { $0 == selection } }
        self.selection = nil
    }
}

private struct SearchIndexRow: View {
    @Environment(SessionLibrary.self) private var library
    @State private var bytes: Int64 = 0

    var body: some View {
        let search = library.transcriptSearch
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(PathText.abbreviated(search.indexFile))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(search.indexFile.path)
                Spacer()
                SizeText(bytes: bytes)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let progress = search.progressText {
                    ProgressView().controlSize(.small)
                    Text(progress).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Button("Reveal in Finder") { PathText.reveal(search.indexFile) }
                Button("Rebuild") { search.rebuild() }
                    .disabled(!search.isAllowed)
                    .help(search.isAllowed ? "Read every transcript again to rebuild the index" : "Turn on Search inside transcripts first")
                Button("Clear Index") {
                    search.clearIndex()
                    bytes = search.indexBytes
                }
                .disabled(bytes == 0)
                .help(bytes == 0 ? "The index is empty" : "Delete the index and the words it holds")
            }
        }
        .task(id: search.progressText) { bytes = search.indexBytes }
    }
}

private struct NightlyHourPicker: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Picker("Nightly run at", selection: settings.binding(\.nightlyHour)) {
            ForEach(DomovySettings.nightlyHourRange, id: \.self) { hour in
                Text(Self.text(hour)).tag(hour)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    static func text(_ hour: Int) -> String {
        let date = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
}

private struct ConnectRow: View {
    @State private var summary: String?
    @State private var showsSheet = false

    var body: some View {
        HStack(spacing: 8) {
            Text(summary ?? "Checking\u{2026}")
                .foregroundStyle(.secondary)
            Button("Connect Agents\u{2026}") { showsSheet = true }
        }
        .sheet(isPresented: $showsSheet, onDismiss: { Task { await load() } }) { ConnectAgentsSheet() }
        .task { await load() }
    }

    private func load() async {
        let connector = AgentConnector(home: AppEnvironment.home, isCustomHome: AppEnvironment.isDevHome, storeRoot: AppEnvironment.storeRoot)
        let command = DomoCommand.registered(await DomoCommand.status()).map {
            MCPRegistration.serverCommand(domo: $0, home: AppEnvironment.home, isCustomHome: AppEnvironment.isDevHome)
        } ?? []
        let plan = await Task.detached { connector.plan(.connect, command: command) }.value
        let detected = plan.agents.filter { $0.state != .notDetected }
        let connected = detected.filter(\.isConnected).count
        summary = detected.isEmpty ? "No agents found" : "\(connected) of \(detected.count) connected"
    }
}

private struct FullDiskAccessRow: View {
    @State private var status: FullDiskAccess.Status?

    var body: some View {
        HStack(spacing: 8) {
            switch status {
            case .granted: Label("On", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            case .denied: Label("Off", systemImage: "minus.circle").foregroundStyle(.secondary)
            case .unknown: Label("Unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary)
            case nil: Text("Checking\u{2026}").foregroundStyle(.secondary)
            }
            Button("Open System Settings") {
                if let url = FullDiskAccess.settingsURL { NSWorkspace.shared.open(url) }
            }
        }
        .task { status = await Task.detached { FullDiskAccess.status() }.value }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { status = await Task.detached { FullDiskAccess.status() }.value }
        }
    }
}

private struct SettingsFileRow: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(PathText.abbreviated(settings.store.file))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button("Reveal in Finder") {
                    settings.ensureFile()
                    PathText.reveal(settings.store.file)
                }
                Button("Open settings.json") {
                    settings.ensureFile()
                    NSWorkspace.shared.open(settings.store.file)
                }
            }
            ForEach(settings.issues, id: \.self) { issue in
                Label(issue.text + (issue.key.isEmpty ? "" : " Using the default."), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = settings.saveError {
                Label("Could not save: \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ResetAllButton: View {
    @Environment(AppSettings.self) private var settings
    @State private var confirming = false

    var body: some View {
        Button("Reset All\u{2026}") { confirming = true }
            .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirming) {
                Button("Reset All Settings", role: .destructive) { settings.resetAll() }
            } message: {
                Text("Sessions, rules, undo history and the search index are not changed. Open at login stays as it is.")
            }
    }
}
