import DomovyCore
import SwiftUI

/// Settings > a category in the sidebar.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, sessions, safety, agents, search, rules, connect, privacy, advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .sessions: "Sessions"
        case .safety: "Safety"
        case .agents: "Agents"
        case .search: "Search"
        case .rules: "Cleanup Rules"
        case .connect: "Connect Agents"
        case .privacy: "Privacy"
        case .advanced: "Advanced"
        }
    }

    /// Badge color, like System Settings' rounded squares. No yellow, orange or brown.
    var tint: Color {
        switch self {
        case .general, .advanced: .gray
        case .sessions: .indigo
        case .safety: .green
        case .agents: .purple
        case .search: .blue
        case .rules: .teal
        case .connect: .cyan
        case .privacy: .blue
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .sessions: "bubble.left.and.text.bubble.right"
        case .safety: "arrow.uturn.backward.circle"
        case .agents: "person.2"
        case .search: "magnifyingglass"
        case .rules: "checklist"
        case .connect: "point.3.connected.trianglepath.dotted"
        case .privacy: "hand.raised"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

/// One setting: what it is called, one line on what it does, and its control. Settings stored
/// in `settings.json` name their key, which gives them a reset button once changed.
struct SettingItem: Identifiable {
    enum Layout {
        /// Title and description on the left, the control on the right.
        case inline
        /// The control below the text (lists, groups of checkboxes).
        case stacked
    }

    let id: String
    let category: SettingsCategory
    let title: String
    let detail: String
    /// The section of its category's pane ("Menu bar"); empty for the first, untitled one.
    var group = ""
    var keywords: [String] = []
    var key: DomovySettings.Key?
    var layout: Layout = .inline
    /// For settings that are part of a key (one agent of `agents.hidden`).
    var isModified: (@MainActor (DomovySettings) -> Bool)?
    var reset: (@MainActor (AppSettings) -> Void)?
    let control: AnyView

    @MainActor
    func modified(_ settings: DomovySettings) -> Bool {
        if let isModified { return isModified(settings) }
        return key.map { !settings.isDefault($0) } ?? false
    }

    @MainActor
    func resetToDefault(_ settings: AppSettings) {
        if let reset { reset(settings) } else if let key { settings.reset(key) }
    }

    /// Every word of the query appears in the title, description, keywords or category.
    func matches(_ query: String) -> Bool {
        let haystack = ([title, detail, category.title, key?.rawValue ?? ""] + keywords).joined(separator: " ")
        return query.split(separator: " ").allSatisfy { haystack.localizedStandardContains($0) }
    }
}

/// The Settings window (⌘,): categories in a sidebar, a search field that finds settings in
/// every category, and grouped forms like System Settings.
struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(RulesController.self) private var rules
    @State private var selection: SettingsCategory? = AppEnvironment.startSettingsPane ?? .general
    @State private var query = ""
    @State private var agentStatuses = AgentStatuses()

    var body: some View {
        // Each rule is searchable too; its pane shows them in the rules list instead.
        let items = SettingsCatalog.items() + SettingsCatalog.ruleItems(rules.rules)
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label {
                    Text(category.title)
                } icon: {
                    CategoryIcon(category: category)
                }
                .badge(badge(category, items: items))
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                // In the sidebar itself, like System Settings: `.searchable` adds a toolbar row.
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search settings", text: $query, prompt: Text("Search"))
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button("Clear search", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 280)
        } detail: {
            Group {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    pane(selection ?? .general, items: items)
                } else {
                    results(items)
                }
            }
            .navigationTitle(query.isEmpty ? (selection ?? .general).title : "Search Results")
        }
        .environment(agentStatuses)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 520, idealHeight: 620)
        .task { await agentStatuses.load() }
        .onChange(of: settings.requestedPane, initial: true) { _, pane in
            guard let pane else { return }
            query = ""
            selection = pane
            settings.requestedPane = nil
        }
    }

    /// How many settings matching the search are in this category.
    private func badge(_ category: SettingsCategory, items: [SettingItem]) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return 0 }
        return items.filter { $0.category == category && $0.matches(trimmed) }.count
    }

    @ViewBuilder
    private func pane(_ category: SettingsCategory, items: [SettingItem]) -> some View {
        if category == .rules {
            let plain = items.filter { $0.category == .rules && !SettingsCatalog.isRuleItem($0) }
            RulesView(settingRows: AnyView(ForEach(plain) { SettingRow(item: $0, query: "") }))
        } else {
            form(category, items: items)
        }
    }

    private func form(_ category: SettingsCategory, items: [SettingItem]) -> some View {
        Form {
            ForEach(SettingsCatalog.sections(category, items: items), id: \.title) { section in
                Section {
                    ForEach(section.items) { SettingRow(item: $0, query: "") }
                } header: {
                    if !section.title.isEmpty { Text(section.title) }
                } footer: {
                    if let footer = section.footer {
                        Text(footer).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func results(_ items: [SettingItem]) -> some View {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let found = items.filter { $0.matches(trimmed) }
        if found.isEmpty {
            ContentUnavailableView.search(text: trimmed)
        } else {
            Form {
                ForEach(SettingsCategory.allCases) { category in
                    let inCategory = found.filter { $0.category == category }
                    if !inCategory.isEmpty {
                        Section(category.title) {
                            ForEach(inCategory) { SettingRow(item: $0, query: trimmed) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// A setting's title (search matches highlighted), description, control and, once changed,
/// a marker and Reset to Default.
private struct SettingRow: View {
    @Environment(AppSettings.self) private var settings
    let item: SettingItem
    let query: String

    var body: some View {
        switch item.layout {
        case .inline:
            LabeledContent {
                item.control
            } label: {
                label
            }
        case .stacked:
            VStack(alignment: .leading, spacing: 8) {
                label
                item.control
            }
        }
    }

    private var label: some View {
        let modified = item.modified(settings.settings)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(Highlight.text(item.title, query: query))
                if modified {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Changed")
                        .help("Changed from the default")
                    Button {
                        item.resetToDefault(settings)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Reset to default")
                    .accessibilityLabel("Reset \(item.title) to default")
                }
            }
            Text(Highlight.text(item.detail, query: query))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Search matches in bold with a light tint behind them.
enum Highlight {
    static func text(_ string: String, query: String) -> AttributedString {
        var text = AttributedString(string)
        for word in query.split(separator: " ") where !word.isEmpty {
            var searchStart = text.startIndex
            while searchStart < text.endIndex,
                  let range = text[searchStart...].range(of: String(word), options: [.caseInsensitive, .diacriticInsensitive]) {
                text[range].inlinePresentationIntent = .stronglyEmphasized
                text[range].backgroundColor = Color.accentColor.opacity(0.22)
                searchStart = range.upperBound
            }
        }
        return text
    }
}

/// A white symbol on a small rounded square of the category's color.
private struct CategoryIcon: View {
    let category: SettingsCategory

    var body: some View {
        Image(systemName: category.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(category.tint.gradient, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}
