import AppKit
import DomovyCore
import SwiftUI

/// The table's rows and selection, apart from the sessions view's state: a selection change
/// redraws only the views that read it (table, inspector, toolbar buttons), and what they
/// need from it is worked out once per change.
@MainActor
@Observable
final class SessionsTableModel {
    var selection: Set<Session.ID> {
        didSet { if selection != oldValue { updateSelected() } }
    }
    /// The filtered, sorted rows on screen.
    private(set) var rows: [SessionRow] = []
    private(set) var totalBytes: Int64 = 0
    /// Tokens and cost of the rows that record them, for the subtitle.
    private(set) var totalTokens: TokenUsage = TokenUsage()
    /// Selected sessions in table order.
    private(set) var selectedSessions: [Session] = []
    /// The one selected session, or nil when none or several are selected. Found among all
    /// sessions, so a filter that hides it does not empty the inspector.
    private(set) var selectedSession: Session?

    /// Bumped when a sort replaces the rows (see `SessionRow.tableID`).
    private(set) var generation = 0
    /// Row indexes of the selection, for putting it back after a sort.
    private(set) var selectedRows = IndexSet()
    @ObservationIgnored private var allByID: [Session.ID: Session] = [:]
    @ObservationIgnored private var rowIndex: [Session.ID: Int] = [:]

    init(selection: Set<Session.ID>) {
        self.selection = selection
    }

    /// "12 sessions · 1.2 GB · 3.4M tokens · ≈ $4.20 est."
    var subtitle: String {
        var text = "\(rows.count) \(rows.count == 1 ? "session" : "sessions") \u{00B7} \(totalBytes.formatted(.byteCount(style: .file)))"
        guard !totalTokens.isEmpty else { return text }
        text += " \u{00B7} \(TokenCounts.compact(totalTokens.totals.total)) tokens"
        if let cost = totalTokens.cost, cost.source == .priceTable || cost.usd > 0 { text += " \u{00B7} \(cost.text) est." }
        return text
    }

    /// What Quick Look, Get Info and scrolling use: the first selected row.
    var primarySession: Session? { selectedSession ?? selectedSessions.first }

    func session(_ id: Session.ID) -> Session? { allByID[id] }

    /// Every session, after a reload or scan.
    func setAll(_ rows: [SessionRow]) {
        allByID = Dictionary(rows.map { ($0.id, $0.session) }, uniquingKeysWith: { first, _ in first })
    }

    /// `reordered` when the sort changed: the rows then get a new table identity.
    func setRows(_ rows: [SessionRow], reordered: Bool = false) {
        let generation = reordered ? self.generation + 1 : self.generation
        let rows = generation == 0 ? rows : rows.map { row in
            var row = row
            row.generation = generation
            return row
        }
        rowIndex = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        // SwiftUI may redraw between these assignments: the selection first, so the table never
        // sees new rows with old row indexes, and the generation last.
        updateSelected(in: rows)
        totalBytes = rows.reduce(0) { $0 + $1.sizeBytes }
        let tokens = rows.lazy.compactMap(\.usage).reduce(TokenUsage(), +)
        if tokens != totalTokens { totalTokens = tokens }
        self.rows = rows
        if generation != self.generation { self.generation = generation }
    }

    private func updateSelected(in rows: [SessionRow]? = nil) {
        let rows = rows ?? self.rows
        let indexes = IndexSet(selection.compactMap { rowIndex[$0] })
        if indexes != selectedRows { selectedRows = indexes }
        let selected = indexes.map { rows[$0].session }
        if selected != selectedSessions { selectedSessions = selected }
        let single = selection.count == 1 ? selection.first.flatMap { allByID[$0] } : nil
        if single != selectedSession { selectedSession = single }
    }
}

/// The sessions table's columns by customization id, for Settings > Sessions.
enum SessionColumn {
    /// Every column with its title; the title column always shows.
    static let optional: [(id: String, title: String)] = [
        ("agent", "Agent"), ("project", "Project"), ("lastActive", "Last active"), ("size", "Size"),
        ("tokens", "Tokens"), ("cost", "Cost (est.)"), ("status", "Status"),
    ]

    static func customization(hidden: [String]) -> TableColumnCustomization<SessionRow> {
        var columns = TableColumnCustomization<SessionRow>()
        apply(hidden: hidden, to: &columns)
        return columns
    }

    static func apply(hidden: [String], to columns: inout TableColumnCustomization<SessionRow>) {
        for column in optional {
            columns[visibility: column.id] = hidden.contains(column.id) ? .hidden : .visible
        }
    }

    /// Hidden columns in table order.
    static func hidden(in columns: TableColumnCustomization<SessionRow>) -> [String] {
        optional.map(\.id).filter { columns[visibility: $0] == .hidden }
    }

    static func sortOrder(_ sort: DomovySettings.SessionSort) -> [KeyPathComparator<SessionRow>] {
        switch sort {
        case .lastActive: [KeyPathComparator(\SessionRow.lastActive, order: .reverse)]
        case .size: [KeyPathComparator(\SessionRow.sizeBytes, order: .reverse)]
        case .title: [KeyPathComparator(\SessionRow.title)]
        case .agent: [KeyPathComparator(\SessionRow.agentLabel)]
        case .project: [KeyPathComparator(\SessionRow.project)]
        case .status: [KeyPathComparator(\SessionRow.statusSortKey)]
        }
    }
}

/// The sessions table. Rows have one fixed height (see `TableTuner`).
struct SessionsTable<MenuItems: View>: View {
    let model: SessionsTableModel
    @Binding var sortOrder: [KeyPathComparator<SessionRow>]
    @Binding var columns: TableColumnCustomization<SessionRow>
    @ViewBuilder let menu: (Set<Session.ID>) -> MenuItems
    let onOpen: (Session) -> Void
    let onDelete: () -> Void

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            Table(of: SessionRow.self, selection: $model.selection, sortOrder: $sortOrder, columnCustomization: $columns) {
                TableColumn("Title", value: \.title) { row in
                    HStack(spacing: 6) {
                        if row.memberCount > 1 {
                            Image(systemName: "square.stack")
                                .foregroundStyle(.secondary)
                                .help("\(row.memberCount) chats shown as one row")
                        }
                        Text(row.title).lineLimit(1)
                    }
                }
                .width(min: 180, ideal: 320)
                .customizationID("title")
                TableColumn("Agent", value: \.agentLabel) { row in
                    HStack(spacing: 6) {
                        AgentGlyph(agent: row.session.agent)
                        Text(row.agentLabel)
                            .lineLimit(1)
                    }
                    .help(row.agentHelp)
                }
                .width(min: 100, ideal: 150)
                .customizationID("agent")
                TableColumn("Project", value: \.project) { Text($0.project.isEmpty ? "—" : $0.project).foregroundStyle(.secondary) }
                    .width(min: 80, ideal: 100)
                    .customizationID("project")
                TableColumn("Last active", value: \.lastActive) { row in
                    Text(row.relativeDate)
                        .foregroundStyle(.secondary)
                        .help(row.absoluteDate)
                }
                .width(min: 90, ideal: 100)
                .customizationID("lastActive")
                TableColumn("Size", value: \.sizeBytes) { row in
                    Text(row.sizeText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(row.exactBytes)
                }
                .width(min: 76, ideal: 88)
                .customizationID("size")
                TableColumn("Tokens", value: \.tokenSortKey) { row in
                    Text(row.tokensText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(row.tokensHelp)
                }
                .width(min: 64, ideal: 72)
                .customizationID("tokens")
                TableColumn("Cost (est.)", value: \.costSortKey) { row in
                    Text(row.costText)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(row.costHelp)
                }
                .width(min: 72, ideal: 80)
                .customizationID("cost")
                TableColumn("Status", value: \.statusSortKey) { row in
                    HStack(spacing: 6) {
                        // Baked into the row, so a sort does not make every cell observe the library.
                        if let status = row.busyStatus {
                            Label {
                                Text(status)
                            } icon: {
                                ProgressView().controlSize(.mini)
                            }
                            .foregroundStyle(.secondary)
                        } else {
                            StatusLabel(session: row.session)
                        }
                        SecretMarker(count: row.secretCount)
                    }
                }
                .width(min: 96, ideal: 116)
                .customizationID("status")
            } rows: {
                // Identity includes the sort generation: a new sort replaces the rows instead of
                // moving each one, which takes AppKit seconds with hundreds of rows.
                ForEach(model.rows, id: \.tableID) { TableRow($0) }
            }
            // An overlay joins the window after the table, so it finds it before its first layout.
            .overlay(TableTuner(generation: model.generation, selectedRows: model.selectedRows).allowsHitTesting(false).accessibilityHidden(true))
            .contextMenu(forSelectionType: Session.ID.self) { ids in
                menu(ids)
            } primaryAction: { ids in
                if let session = model.rows.first(where: { ids.contains($0.id) })?.session { onOpen(session) }
            }
            .onDeleteCommand(perform: onDelete)
            .onKeyPress(.space) {
                guard let session = model.primarySession else { return .ignored }
                onOpen(session)
                return .handled
            }
            .onChange(of: sortOrder) {
                guard let first = model.primarySession?.id else { return }
                Task { proxy.scrollTo(first, anchor: .center) }
            }
        }
    }
}

/// Two fixes on the table beside it, found through the view hierarchy:
/// - Turns off automatic row heights. SwiftUI's `Table` turns them on, and then AppKit sizes
///   every visible cell's hosting view on each reload, sort and selection change; the cells
///   here are one line, so one height fits all. It keeps the height AppKit chose for rows, so
///   it follows the system's table size.
/// - After a sort replaced the rows, puts the selection back at once: SwiftUI hands it to the
///   new rows only a moment later, so the highlight blinked.
private struct TableTuner: NSViewRepresentable {
    let generation: Int
    let selectedRows: IndexSet

    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) {
        view.apply()
        guard generation != view.generation else { return }
        view.generation = generation
        let rows = selectedRows
        // After this update has given the table its new rows.
        DispatchQueue.main.async { [weak view] in view?.select(rows) }
    }

    final class Probe: NSView {
        var generation = 0
        private weak var table: NSTableView?

        func select(_ rows: IndexSet) {
            guard let table = enclosingTable(), table.selectedRowIndexes != rows,
                  rows.allSatisfy({ $0 < table.numberOfRows }) else { return }
            table.selectRowIndexes(rows, byExtendingSelection: false)
        }

        /// Clicks go to the table underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            // When the table joins the window after this view, catch it before it draws.
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let table = enclosingTable(), table.usesAutomaticRowHeights else { return }
            // AppKit's estimate is the system row height for the table's size; a row already
            // laid out gives the measured one.
            let measured = table.numberOfRows > 0 ? table.rect(ofRow: 0).height - table.intercellSpacing.height : 0
            let height = measured > 0 ? measured : table.rowHeight
            guard height > 0 else { return }
            table.usesAutomaticRowHeights = false
            table.rowHeight = height
        }

        /// The nearest multi-column table beside this view (SwiftUI's `Table` is an outline
        /// view; the sidebar's one-column list never matches).
        private func enclosingTable() -> NSTableView? {
            if let table, table.window === window { return table }
            table = findTable()
            return table
        }

        private func findTable() -> NSTableView? {
            var ancestor = superview
            for _ in 0..<6 {
                guard let view = ancestor else { return nil }
                if let table = Self.firstTable(in: view) { return table }
                ancestor = view.superview
            }
            return nil
        }

        private static func firstTable(in view: NSView) -> NSTableView? {
            var queue = [view]
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if let table = next as? NSTableView, table.numberOfColumns > 1 { return table }
                queue += next.subviews
            }
            return nil
        }
    }
}

/// How the rows are shown: changing it filters and sorts the formatted rows again.
struct RowView: Equatable {
    let agentFilter: AgentKind?
    let statusFilter: StatusFilter
    let showsFlaggedOnly: Bool
    let search: String
    let sortOrder: [KeyPathComparator<SessionRow>]

    func apply(to rows: [SessionRow]) -> [SessionRow] {
        let needle = search.lowercased()
        return rows
            .filter { row in
                let session = row.session
                return (agentFilter == nil || session.agent == agentFilter)
                    && statusFilter.matches(session)
                    && (!showsFlaggedOnly || row.secretCount > 0)
                    && (needle.isEmpty || row.searchKey.contains(needle))
            }
            .sortedFast(using: sortOrder)
    }
}

extension Array where Element == SessionRow {
    /// `sorted(using:)` for one column, with the comparison written out: the generic
    /// comparator costs tens of milliseconds a sort with hundreds of rows. Same order:
    /// text the Finder's way (`localizedStandard`), ties kept in place.
    func sortedFast(using order: [KeyPathComparator<SessionRow>]) -> [SessionRow] {
        guard order.count == 1, let comparator = order.first else { return sorted(using: order) }
        let forward = comparator.order == .forward
        func by<T: Comparable>(_ key: (SessionRow) -> T) -> [SessionRow] {
            sorted { forward ? key($0) < key($1) : key($1) < key($0) }
        }
        func byText(_ key: (SessionRow) -> String) -> [SessionRow] {
            sorted {
                let result = key($0).localizedStandardCompare(key($1))
                return forward ? result == .orderedAscending : result == .orderedDescending
            }
        }
        switch comparator.keyPath {
        case \SessionRow.title: return byText(\.title)
        case \SessionRow.agentLabel: return byText(\.agentLabel)
        case \SessionRow.project: return byText(\.project)
        case \SessionRow.statusSortKey: return byText(\.statusSortKey)
        case \SessionRow.lastActive: return by(\.lastActive)
        case \SessionRow.sizeBytes: return by(\.sizeBytes)
        case \SessionRow.tokenSortKey: return by(\.tokenSortKey)
        case \SessionRow.costSortKey: return by(\.costSortKey)
        default: return sorted(using: order)
        }
    }
}

/// One sessions-table row with its text formatted up front: cells only read strings.
struct SessionRow: Identifiable, Equatable, Sendable {
    let session: Session
    let title: String
    let agentLabel: String
    let agentHelp: String
    let project: String
    let lastActive: Date
    let relativeDate: String
    let absoluteDate: String
    let sizeBytes: Int64
    let sizeText: String
    let exactBytes: String
    let statusSortKey: String
    let secretCount: Int
    /// What a background archive or delete is doing to it ("Archiving…").
    let busyStatus: String?
    /// Recorded tokens; `nil` when unknown or not recorded.
    let usage: TokenUsage?
    /// Total tokens; -1 when the agent records none, so those sort last.
    let tokenSortKey: Int64
    let tokensText: String
    let tokensHelp: String
    /// Estimated dollars; -1 when there is no estimate.
    let costSortKey: Double
    let costText: String
    let costHelp: String
    /// Title and project, lowercased once for search.
    let searchKey: String
    /// Sort generation, set by `SessionsTableModel` (see `tableID`).
    var generation = 0

    var tableID: String { "\(generation)#\(session.id)" }

    var id: Session.ID { session.id }
    var memberCount: Int { session.memberCount }

    private static let relativeStyle = Date.RelativeFormatStyle(presentation: .named)
    private static let absoluteStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
    private static let sizeStyle = ByteCountFormatStyle(style: .file)

    init(_ session: Session, secretCount: Int, tokens: TokenUsageResult? = nil, recordsTokens: Bool = false, busyStatus: String? = nil) {
        self.session = session
        title = session.displayTitle
        agentLabel = session.agentLabel
        agentHelp = session.desktopHelp ?? session.agent.displayName
        project = session.sortProject
        lastActive = session.lastActive
        relativeDate = Self.relativeStyle.format(session.lastActive)
        absoluteDate = Self.absoluteStyle.format(session.lastActive)
        sizeBytes = session.sizeBytes
        sizeText = Self.sizeStyle.format(session.sizeBytes)
        exactBytes = "\(session.sizeBytes.formatted()) bytes"
        statusSortKey = session.status.rawValue
        self.secretCount = secretCount
        self.busyStatus = busyStatus
        let usage = tokens?.usage
        self.usage = usage
        tokenSortKey = usage?.totals.total ?? -1
        tokensText = usage.map { TokenCounts.compact($0.totals.total) } ?? "\u{2014}"
        let cost = usage?.cost
        costSortKey = cost?.usd ?? -1
        costText = cost.map { $0.compactText + ($0.isPartial ? "+" : "") } ?? "\u{2014}"
        switch (usage, tokens, recordsTokens) {
        case (let usage?, _, _):
            tokensHelp = usage.breakdown
            costHelp = cost.map { "\($0.text). \($0.explanation)" } ?? "No estimate: Domovy's price table does not know \(usage.models.isEmpty ? "the model" : usage.models.joined(separator: ", "))."
        case (nil, .notRecorded?, _):
            tokensHelp = "\(session.agent.displayName) recorded no token usage for this session."
            costHelp = tokensHelp
        case (nil, nil, true):
            tokensHelp = "Counting tokens\u{2026}"
            costHelp = tokensHelp
        default:
            tokensHelp = "\(session.agent.displayName) does not record token usage."
            costHelp = tokensHelp
        }
        searchKey = (title + "\n" + project).lowercased()
    }

    /// Rows for every session, formatted off the main actor.
    static func build(_ sessions: [Session], findingCounts: [Session.ID: Int], tokens: [Session.ID: TokenUsageResult] = [:],
                      tokenAgents: Set<AgentKind> = [], busy: [Session.ID: String] = [:]) async -> [SessionRow] {
        await Task.detached {
            sessions.map {
                SessionRow($0, secretCount: findingCounts[$0.id] ?? 0, tokens: tokens[$0.id],
                           recordsTokens: tokenAgents.contains($0.agent), busyStatus: busy[$0.id])
            }
        }.value
    }
}
