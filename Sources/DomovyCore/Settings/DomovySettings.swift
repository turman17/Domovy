import Foundation

/// Domovy's settings, shared by the app, `domo` and the MCP server. Defaults live here, in
/// code; `settings.json` in Domovy's folder holds only the values someone changed, under flat
/// dotted keys like VS Code's (`"safety.deleteDestination": "quarantine"`). Keys Domovy does
/// not know are kept as they are, so a newer or older version never drops them.
public struct DomovySettings: Equatable, Sendable {
    /// What the menu bar item shows next to its icon, or that it is hidden.
    public enum MenuBarDisplay: String, CaseIterable, Sendable {
        case iconOnly, totalSize, reclaimableSize, liveSessions, hidden
    }

    /// The first section of the main window.
    public enum LaunchSection: String, CaseIterable, Sendable {
        case sessions, disk, processes
    }

    /// The sessions table's sort when the window opens.
    public enum SessionSort: String, CaseIterable, Sendable {
        /// Newest first.
        case lastActive
        /// Largest first.
        case size
        /// A to Z.
        case title
        case agent
        case project
        case status
    }

    public enum SessionsLayout: String, CaseIterable, Sendable {
        case list, projects
    }

    /// Every key of `settings.json` Domovy reads.
    public enum Key: String, CaseIterable, Sendable {
        case menuBarDisplay = "menuBar.display"
        case popoverShowsBreakdown = "menuBar.popover.breakdown"
        case popoverShowsAttention = "menuBar.popover.attention"
        case popoverShowsRules = "menuBar.popover.rules"
        case showsInDock = "app.showInDock"
        case launchSection = "app.launchSection"
        case defaultSort = "sessions.defaultSort"
        case hiddenColumns = "sessions.hiddenColumns"
        case sessionsLayout = "sessions.layout"
        case expiringWindowDays = "sessions.expiringWarningDays"
        case deleteDestination = "safety.deleteDestination"
        case hiddenAgents = "agents.hidden"
        case aiderSearchFolders = "agents.aider.searchFolders"
        case transcriptIndex = "search.transcriptIndex"
        case nightlyHour = "rules.nightlyHour"
    }

    public static let expiringWindowRange = 1...30
    public static let nightlyHourRange = 0...23

    // General
    public var menuBarDisplay: MenuBarDisplay = .iconOnly
    public var popoverShowsBreakdown = true
    public var popoverShowsAttention = true
    public var popoverShowsRules = true
    /// Off: menu bar only (an accessory app). Ignored while the menu bar item is hidden.
    public var showsInDock = true
    public var launchSection: LaunchSection = .sessions
    // Sessions
    public var defaultSort: SessionSort = .lastActive
    /// Column ids of the sessions table the user hid ("tokens", "cost").
    public var hiddenColumns: [String] = []
    public var sessionsLayout: SessionsLayout = .list
    /// Claude Code and Gemini CLI sessions this many days from their agent's sweep are `.expiring`.
    public var expiringWindowDays = 7
    // Safety
    /// Where deletes go when nothing else says: the app's sheets start on it, `domo rm` and
    /// the MCP server use it without `--to` / `destination`.
    public var deleteDestination: Destination = .trash
    // Agents
    /// Agents left out of every list, scan and footprint.
    public var hiddenAgents: Set<AgentKind> = []
    /// Folders Domovy looks in (and one level below) for Aider's history files. `~/` allowed.
    public var aiderSearchFolders: [String] = []
    // Search
    /// Off: transcripts are never indexed and the Transcripts search scope is unavailable.
    public var transcriptIndex = true
    // Rules
    /// Local hour of the nightly rules run.
    public var nightlyHour = 3

    /// Keys this version does not know, kept for writing back.
    public var unknown: [String: JSONValue] = [:]

    public init() {}

    /// The menu bar item is shown.
    public var showsMenuBarItem: Bool { menuBarDisplay != .hidden }
    /// Hiding the menu bar item keeps the Dock icon, so Domovy stays reachable.
    public var effectiveShowsInDock: Bool { showsInDock || !showsMenuBarItem }

    public func isHidden(_ agent: AgentKind) -> Bool { hiddenAgents.contains(agent) }

    /// Where a delete goes: the one asked for (`--to`, an MCP `destination`), else the default.
    public func destination(_ explicit: Destination?) -> Destination { explicit ?? deleteDestination }

    /// The value stays at its default.
    public func isDefault(_ key: Key) -> Bool {
        value(for: key) == DomovySettings().value(for: key)
    }

    /// Puts one value back to its default.
    public mutating func reset(_ key: Key) {
        let defaults = DomovySettings()
        switch key {
        case .menuBarDisplay: menuBarDisplay = defaults.menuBarDisplay
        case .popoverShowsBreakdown: popoverShowsBreakdown = defaults.popoverShowsBreakdown
        case .popoverShowsAttention: popoverShowsAttention = defaults.popoverShowsAttention
        case .popoverShowsRules: popoverShowsRules = defaults.popoverShowsRules
        case .showsInDock: showsInDock = defaults.showsInDock
        case .launchSection: launchSection = defaults.launchSection
        case .defaultSort: defaultSort = defaults.defaultSort
        case .hiddenColumns: hiddenColumns = defaults.hiddenColumns
        case .sessionsLayout: sessionsLayout = defaults.sessionsLayout
        case .expiringWindowDays: expiringWindowDays = defaults.expiringWindowDays
        case .deleteDestination: deleteDestination = defaults.deleteDestination
        case .hiddenAgents: hiddenAgents = defaults.hiddenAgents
        case .aiderSearchFolders: aiderSearchFolders = defaults.aiderSearchFolders
        case .transcriptIndex: transcriptIndex = defaults.transcriptIndex
        case .nightlyHour: nightlyHour = defaults.nightlyHour
        }
    }

    /// Aider's search folders as absolute URLs: `~/` expanded against `home`, relative paths
    /// left out.
    public func aiderSearchURLs(home: URL) -> [URL] {
        aiderSearchFolders.compactMap { Self.folderURL($0, home: home) }
    }

    static func folderURL(_ path: String, home: URL) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        let expanded = trimmed == "~" ? home.path
            : trimmed.hasPrefix("~/") ? home.appendingPathComponent(String(trimmed.dropFirst(2))).path : trimmed
        return expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true) : nil
    }

    // MARK: JSON

    /// One value of a key as JSON.
    public func value(for key: Key) -> JSONValue {
        switch key {
        case .menuBarDisplay: .string(menuBarDisplay.rawValue)
        case .popoverShowsBreakdown: .bool(popoverShowsBreakdown)
        case .popoverShowsAttention: .bool(popoverShowsAttention)
        case .popoverShowsRules: .bool(popoverShowsRules)
        case .showsInDock: .bool(showsInDock)
        case .launchSection: .string(launchSection.rawValue)
        case .defaultSort: .string(defaultSort.rawValue)
        case .hiddenColumns: .array(hiddenColumns.map(JSONValue.string))
        case .sessionsLayout: .string(sessionsLayout.rawValue)
        case .expiringWindowDays: .int(expiringWindowDays)
        case .deleteDestination: .string(deleteDestination.rawValue)
        case .hiddenAgents: .array(hiddenAgents.map(\.rawValue).sorted().map(JSONValue.string))
        case .aiderSearchFolders: .array(aiderSearchFolders.map(JSONValue.string))
        case .transcriptIndex: .bool(transcriptIndex)
        case .nightlyHour: .int(nightlyHour)
        }
    }

    /// The object written to `settings.json`: changed values and unknown keys.
    public var jsonObject: [String: JSONValue] {
        var object = unknown
        for key in Key.allCases where !isDefault(key) { object[key.rawValue] = value(for: key) }
        return object
    }

    /// Reads an object. A value of the wrong type or out of range falls back to its default
    /// and is reported; unknown keys are kept.
    public static func decode(_ object: [String: JSONValue]) -> (settings: DomovySettings, issues: [SettingsIssue]) {
        var settings = DomovySettings()
        var issues: [SettingsIssue] = []
        for (name, value) in object {
            guard let key = Key(rawValue: name) else {
                settings.unknown[name] = value
                continue
            }
            if let problem = settings.apply(value, to: key) {
                issues.append(SettingsIssue(key: name, message: problem))
            }
        }
        return (settings, issues.sorted { $0.key < $1.key })
    }

    /// Sets `key` from JSON, or says why the value was not used.
    private mutating func apply(_ value: JSONValue, to key: Key) -> String? {
        func choice<T: RawRepresentable & CaseIterable>(_ type: T.Type, _ set: (T) -> Void) -> String? where T.RawValue == String {
            guard let raw = value.stringValue, let parsed = T(rawValue: raw) else {
                return "Expected one of \(T.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", "))."
            }
            set(parsed)
            return nil
        }
        func flag(_ set: (Bool) -> Void) -> String? {
            guard let parsed = value.boolValue else { return "Expected true or false." }
            set(parsed)
            return nil
        }
        func number(_ range: ClosedRange<Int>, _ set: (Int) -> Void) -> String? {
            guard let parsed = value.intValue, range.contains(parsed) else {
                return "Expected a whole number from \(range.lowerBound) to \(range.upperBound)."
            }
            set(parsed)
            return nil
        }
        func strings(_ set: ([String]) -> Void) -> String? {
            guard let items = value.arrayValue?.map(\.stringValue), !items.contains(nil) else { return "Expected a list of strings." }
            set(items.compactMap { $0 })
            return nil
        }
        switch key {
        case .menuBarDisplay: return choice(MenuBarDisplay.self) { menuBarDisplay = $0 }
        case .popoverShowsBreakdown: return flag { popoverShowsBreakdown = $0 }
        case .popoverShowsAttention: return flag { popoverShowsAttention = $0 }
        case .popoverShowsRules: return flag { popoverShowsRules = $0 }
        case .showsInDock: return flag { showsInDock = $0 }
        case .launchSection: return choice(LaunchSection.self) { launchSection = $0 }
        case .defaultSort: return choice(SessionSort.self) { defaultSort = $0 }
        case .hiddenColumns: return strings { hiddenColumns = $0 }
        case .sessionsLayout: return choice(SessionsLayout.self) { sessionsLayout = $0 }
        case .expiringWindowDays: return number(Self.expiringWindowRange) { expiringWindowDays = $0 }
        case .deleteDestination:
            guard let raw = value.stringValue, let parsed = Destination(rawValue: raw) else { return "Expected \"trash\" or \"quarantine\"." }
            deleteDestination = parsed
            return nil
        case .hiddenAgents:
            var unknownNames: [String] = []
            let problem = strings { names in
                var kinds = Set<AgentKind>()
                for name in names {
                    if let kind = AgentKind(rawValue: name) { kinds.insert(kind) } else { unknownNames.append(name) }
                }
                hiddenAgents = kinds
            }
            if let problem { return problem }
            return unknownNames.isEmpty ? nil : "Unknown agent \(unknownNames.map { "\"\($0)\"" }.joined(separator: ", ")), ignored."
        case .aiderSearchFolders:
            return strings { aiderSearchFolders = $0 }
        case .transcriptIndex: return flag { transcriptIndex = $0 }
        case .nightlyHour: return number(Self.nightlyHourRange) { nightlyHour = $0 }
        }
    }
}

/// A value in `settings.json` Domovy could not use, shown in Settings > Advanced.
public struct SettingsIssue: Hashable, Sendable {
    /// The key, or empty for the file as a whole.
    public let key: String
    public let message: String

    public init(key: String, message: String) {
        self.key = key
        self.message = message
    }

    public var text: String { key.isEmpty ? message : "\u{201C}\(key)\u{201D}: \(message)" }
}
