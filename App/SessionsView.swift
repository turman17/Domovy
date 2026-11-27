import DomovyCore
import SwiftUI

/// Sessions to delete. The sheet opens at once and plans them while it shows a spinner.
struct DeleteRequest: Identifiable {
    let id = UUID()
    let sessions: [Session]
    let destination: Destination
    /// Selected sessions left out, one line each ("2 live sessions are left alone.").
    var notes: [String] = []
}

/// Purge originals awaiting confirmation.
struct PurgeRequest: Identifiable {
    let id = UUID()
    let plan: PurgePlan
}

struct SessionsView: View {
    let agentFilter: AgentKind?
    /// Owned by ContentView: `.searchable` must sit on the split view, or SwiftUI can insert
    /// its search toolbar item twice and AppKit aborts the window update.
    let search: String

    @Environment(SessionLibrary.self) private var library
    /// Rows and selection. Only the views that read the selection redraw when it changes.
    @State private var model = SessionsTableModel(selection: Set([AppEnvironment.startSelection].compactMap { $0 }))
    @State private var statusFilter: StatusFilter = .all
    /// Starts on Settings > Sessions > Sort sessions by.
    @State private var sortOrder = SessionColumn.sortOrder(AppSettings.shared.settings.defaultSort)
    /// Column widths, kept here so they survive the table being rebuilt on a sort. Which
    /// columns show is a setting, kept in step both ways.
    @State private var columns = SessionColumn.customization(hidden: AppSettings.shared.settings.hiddenColumns)
    @State private var showInspector = true
    @State private var dismissedBanners: Set<AgentKind> = []
    @State private var deleteRequest: DeleteRequest?
    @State private var archiveRequest: ArchiveRequest?
    @State private var previewSession: Session?
    @State private var infoSession: Session?
    @State private var redactRequest: RedactRequest?
    @State private var purgeRequest: PurgeRequest?
    @State private var showsFlaggedOnly = false
    /// List or By Project: Settings > Sessions, kept across launches.
    private var layout: SessionsLayout { AppSettings.shared.settings.sessionsLayout }
    /// The popover's filter for a moment after it arrives, so the sidebar switch it causes
    /// does not reset it.
    @State private var requestedFilter: StatusFilter?
    @State private var errorMessage: String?
    /// `search` once typing rests: each filter pass redraws the table.
    @State private var appliedSearch = ""
    @State private var searchPace = LoadPace(delay: .milliseconds(150))
    /// The column sort from before a transcript search put its matches best first.
    @State private var sortBeforeSearch: [KeyPathComparator<SessionRow>]?

    /// Empties the toolbar search, which ContentView owns.
    let clearSearch: () -> Void

    init(agentFilter: AgentKind?, search: String, clearSearch: @escaping () -> Void) {
        self.agentFilter = agentFilter
        self.search = search
        self.clearSearch = clearSearch
        _appliedSearch = State(initialValue: search)
    }

    /// Every session as a row, text formatted off the main actor once per reload or scan, so
    /// scrolling draws cells without formatting and sorting only reorders.
    @State private var allRows: [SessionRow] = []
    /// The data `allRows` was built from; until it matches `rowData`, no empty state shows.
    @State private var builtRowData: RowData?

    private var rowData: RowData {
        RowData(revision: library.revision, findingCounts: library.secretFindings.mapValues(\.count),
                tokenRevision: library.tokenRevision, busy: library.busySessions)
    }

    private var rowView: RowView {
        RowView(
            agentFilter: agentFilter,
            statusFilter: statusFilter,
            showsFlaggedOnly: showsFlaggedOnly,
            search: isTranscriptSearch ? "" : appliedSearch,
            sortOrder: sortOrder
        )
    }

    private var isTranscriptSearch: Bool { library.transcriptSearch.scope == .transcripts && !appliedSearch.isEmpty }

    /// The rows on screen: the filters, then the transcript search's matches when it is on.
    private func visibleRows(_ rows: [SessionRow]) -> [SessionRow] {
        let shown = rowView.apply(to: rows)
        return isTranscriptSearch ? library.transcriptSearch.filter(shown, byRelevance: sortOrder.isEmpty) : shown
    }

    /// A transcript search shows its matches best first until a column is clicked; the column
    /// sort from before comes back when it ends.
    private func useRelevanceSort(_ on: Bool) {
        if on, sortBeforeSearch == nil {
            sortBeforeSearch = sortOrder
            sortOrder = []
        } else if !on, let previous = sortBeforeSearch {
            if sortOrder.isEmpty { sortOrder = previous }
            sortBeforeSearch = nil
        }
    }

    private var selectedSessions: [Session] { model.selectedSessions }
    private var selectedSession: Session? { model.selectedSession }
    private var primarySession: Session? { model.primarySession }

    var body: some View {
        VStack(spacing: 0) {
            RetentionBanners(
                agentFilter: agentFilter,
                dismissed: $dismissedBanners,
                onArchiveAll: { requestArchive($0) },
                onReview: { statusFilter = .expiring }
            )
            if library.secretScan != .idle {
                SecretScanBanner(
                    state: library.secretScan,
                    showsFlaggedOnly: showsFlaggedOnly,
                    onToggleFlagged: { showsFlaggedOnly.toggle() },
                    onPurge: requestPurge,
                    onCancel: library.cancelSecretScan,
                    onDismiss: {
                        library.dismissSecretScan()
                        showsFlaggedOnly = false
                    }
                )
            }
            if hasActiveFilters {
                ActiveFiltersBar(
                    search: search,
                    statusFilter: statusFilter,
                    showsFlaggedOnly: showsFlaggedOnly,
                    onClearSearch: clearSearch,
                    onClearStatus: { statusFilter = .all },
                    onClearFlagged: { showsFlaggedOnly = false },
                    onClearAll: clearFilters
                )
                Divider()
            }
            sessionsContent
                .tourAnchor(.sessionsList)
        }
        .onExitCommand { if hasActiveFilters { clearFilters() } }
        .overlay { emptyState }
        .overlay(alignment: .bottom) { toastOverlay }
        .navigationTitle(showsFlaggedOnly ? "Flagged by the secret scan" : statusFilter == .expiring ? "Expiring soon" : (agentFilter?.displayName ?? "Sessions"))
        .navigationSubtitle(model.subtitle)
        .task(id: rowData) {
            let data = rowData
            let built = await SessionRow.build(library.sessions, findingCounts: data.findingCounts, tokens: library.tokenUsage,
                                               tokenAgents: library.tokenAgents, busy: data.busy)
            guard !Task.isCancelled else { return }
            allRows = built
            model.setAll(built)
            model.setRows(visibleRows(built))
            builtRowData = data
        }
        .task(id: search) {
            #if DEBUG
            // The harness times the filter itself, not the wait.
            if AppEnvironment.perfEnabled { appliedSearch = search; return }
            #endif
            guard await searchPace.wait() else { return }
            appliedSearch = search
        }
        .onChange(of: rowView) { old, view in
            model.setRows(visibleRows(allRows), reordered: old.sortOrder != view.sortOrder)
        }
        .onChange(of: library.transcriptSearch.revision) { model.setRows(visibleRows(allRows)) }
        .onChange(of: isTranscriptSearch ? appliedSearch : "", initial: true) { _, text in
            library.transcriptSearch.search(text)
            useRelevanceSort(!text.isEmpty)
        }
        .onChange(of: library.sessions.isEmpty) { _, isEmpty in
            if !isEmpty, AppEnvironment.opensInfoAtLaunch, infoSession == nil { infoSession = primarySession }
        }
        .toolbar { toolbar }
        #if DEBUG
        .onAppear { PerfDriver.shared.rowIDs = { [model] in model.rows.map(\.id) } }
        // In a child view, so a command does not redraw the whole sessions view by itself.
        .background { PerfHook(handle: perfHandle) }
        #endif
        .inspector(isPresented: $showInspector) {
            SelectionInspector(model: model, onArchive: requestArchiveSelection, onDelete: requestDelete, onRedact: requestRedact)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tourAnchor(.inspector)
        }
        .sheet(item: $deleteRequest) { request in
            DeletePlanSheet(request: request)
        }
        .sheet(item: $archiveRequest) { request in
            ArchivePlanSheet(request: request)
        }
        .sheet(item: $infoSession) { session in
            SessionInfoSheet(session: session)
        }
        .sheet(item: $previewSession) { session in
            TranscriptPreviewSheet(session: session)
        }
        .sheet(item: $redactRequest) { request in
            RedactPlanSheet(request: request)
        }
        .sheet(item: $purgeRequest) { request in
            PurgeSheet(plan: request.plan)
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onChange(of: library.actionError) { _, message in
            if let message {
                errorMessage = message
                library.actionError = nil
            }
        }
        .onChange(of: agentFilter) {
            // A filter left over from another agent's "Review" would show an empty table,
            // unless the popover asked for this filter as it switched the sidebar.
            statusFilter = requestedFilter ?? .all
            showsFlaggedOnly = false
        }
        .onChange(of: library.requestedFilter) { _, requested in
            if let requested {
                library.requestedFilter = nil
                statusFilter = requested
                requestedFilter = requested
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    requestedFilter = nil
                }
            }
        }
        .task(id: library.toast?.id) {
            // Toasts fade on their own; undo stays reachable with ⌘Z.
            guard library.toast != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            withAnimation { library.toast = nil }
        }
    }

    // MARK: Pieces

    private var table: some View {
        SessionsTable(model: model, sortOrder: $sortOrder, columns: $columns) { ids in
            // Right-clicking inside a selection gives the whole selection, like the Finder.
            if ids.count > 1 {
                selectionMenu(for: model.rows.filter { ids.contains($0.id) }.map(\.session))
            } else if let id = ids.first, let session = model.session(id) {
                rowMenu(for: session)
            }
        } onOpen: { previewSession = $0 } onDelete: { requestDelete() }
        .onChange(of: columns) { _, columns in
            let hidden = SessionColumn.hidden(in: columns)
            if hidden != AppSettings.shared.settings.hiddenColumns { AppSettings.shared.update { $0.hiddenColumns = hidden } }
        }
        .onChange(of: AppSettings.shared.settings.hiddenColumns) { _, hidden in
            if hidden != SessionColumn.hidden(in: columns) { SessionColumn.apply(hidden: hidden, to: &columns) }
        }
    }

    /// The list or the projects outline, with File > Export Transcript… for the selection.
    private var sessionsContent: some View {
        Group {
            if layout == .projects { projectsView } else { table }
        }
        .focusedSceneValue(\.exportTranscripts, exportAction)
        .focusedSceneValue(\.sessionCommands, sessionCommands)
    }

    /// The Session menu: the same actions as the toolbar, with their shortcuts.
    private var sessionCommands: SessionCommands {
        let primary = model.primarySession
        let sessions = model.selectedSessions
        // Assigned one by one: the memberwise call crashes the Swift 6.4 type checker.
        var commands = SessionCommands()
        if let primary {
            commands.quickLook = { previewSession = primary }
            commands.getInfo = { infoSession = primary }
        }
        if sessions.contains(where: library.canArchive) { commands.archive = { requestArchiveSelection() } }
        if sessions.contains(where: library.canDelete) { commands.delete = { requestDelete() } }
        return commands
    }

    private var exportAction: ExportAction? {
        guard !model.selectedSessions.isEmpty else { return nil }
        return ExportAction { [model, library] in TranscriptExporter.export(model.selectedSessions, library: library) }
    }

    private var projectsView: some View {
        ProjectsView(rows: model.rows) { ids in
            model.selection = ids
        } onOpen: { previewSession = $0 } onArchive: { sessions in
            if sessions.count == 1 { requestArchive(sessions.filter(library.canArchive)) } else { requestArchiveBatch(sessions) }
        } onDelete: { requestDelete($0) } onExport: {
            TranscriptExporter.export($0, library: library)
        } onShowInList: { group in
            AppSettings.shared.update { $0.sessionsLayout = .list }
            library.requestedSearch = group.name
        }
    }

    /// Right-click menu, like the Finder's. Destructive items still open their plan sheet first.
    @ViewBuilder
    private func rowMenu(for session: Session) -> some View {
        Button("Quick Look", systemImage: "eye") { previewSession = session }
        Button("Get Info", systemImage: "info.circle") { infoSession = session }
        Button("Show in Finder", systemImage: "folder") { revealInFinder(session) }
        if let project = session.projectPath, FileManager.default.fileExists(atPath: project) {
            Button("Open Project Folder", systemImage: "folder.badge.gearshape") {
                NSWorkspace.shared.open(URL(fileURLWithPath: project))
            }
        }
        Divider()
        ResumeButtons(session: session)
        if let command = resumeCommand(for: session) {
            Button("Copy Resume Command", systemImage: "doc.on.doc") { copyToPasteboard(command) }
        }
        Button("Copy Session ID", systemImage: "number") { copyToPasteboard(session.id) }
        Button("Copy Transcript Path", systemImage: "doc.on.doc") { copyToPasteboard(session.transcriptURL.path) }
        if let project = session.projectPath {
            Button("Copy Project Path", systemImage: "doc.on.doc") { copyToPasteboard(project) }
        }
        Divider()
        Button("Show Sessions in This Project", systemImage: "line.3.horizontal.decrease") {
            library.requestedSearch = session.projectName
        }
        .disabled(session.projectName == nil)
        .help(session.projectName == nil ? "This session has no project folder" : "")
        Button("Scan for Secrets", systemImage: "key") { library.scanSecrets([session]) }
        Button("Export Transcript\u{2026}", systemImage: "square.and.arrow.up") { TranscriptExporter.export([session], library: library) }
        Divider()
        Button("Archive\u{2026}", systemImage: "archivebox") {
            model.selection = [session.id]
            requestArchive([session])
        }
        .disabled(!library.canArchive(session))
        .help(library.canArchive(session) ? "" : library.readOnlyNote(for: session) ?? unavailableReason(session, archiving: true))
        Button("Move to Trash\u{2026}", systemImage: "trash") {
            model.selection = [session.id]
            requestDelete([session])
        }
        .disabled(!library.canDelete(session))
        .help(library.canDelete(session) ? "" : library.readOnlyNote(for: session) ?? unavailableReason(session, archiving: false))
    }

    /// Why Archive or Move to Trash is off for a session the agent lets Domovy change.
    private func unavailableReason(_ session: Session, archiving: Bool) -> String {
        if session.status == .live { return "This session is live. Quit the \(session.agent.displayName) session using it first." }
        if archiving, session.isArchived { return "This session is already archived." }
        if library.busySessions[session.id] != nil { return "This session is still being archived or moved." }
        return archiving ? "This session has no file to compress." : "This session can\u{2019}t be moved right now."
    }

    /// Right-click menu on several rows: actions that make sense for all of them at once.
    @ViewBuilder
    private func selectionMenu(for sessions: [Session]) -> some View {
        let n = sessions.count
        Button("Copy Session IDs", systemImage: "number") {
            copyToPasteboard(sessions.map(\.id).joined(separator: "\n"))
        }
        Button("Scan \(n) for Secrets", systemImage: "key") { library.scanSecrets(sessions) }
        Button("Export \(n) Transcripts\u{2026}", systemImage: "square.and.arrow.up") { TranscriptExporter.export(sessions, library: library) }
        Divider()
        Button("Archive \(n) Sessions\u{2026}", systemImage: "archivebox") { requestArchiveBatch(sessions) }
            .disabled(!sessions.contains(where: library.canArchive))
            .help(library.commonReadOnlyNote(for: sessions) ?? "")
        Button("Move \(n) Sessions to Trash\u{2026}", systemImage: "trash") { requestDelete(sessions) }
            .disabled(!sessions.contains(where: library.canDelete))
            .help(library.commonReadOnlyNote(for: sessions) ?? "")
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if AppEnvironment.isDevHome, !AppEnvironment.isScreenshot {
            ToolbarItem {
                Label("Dev home", systemImage: "hammer")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.secondary)
                    .help("Reading the fake home in .devhome, not your real one.")
            }
        }
        if let activity = library.backgroundActivity {
            ToolbarItem {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        ToolbarItem {
            Picker("View", selection: AppSettings.shared.binding(\.sessionsLayout)) {
                Label("List", systemImage: "list.bullet").tag(SessionsLayout.list)
                Label("By Project", systemImage: "folder").tag(SessionsLayout.projects)
            }
            .pickerStyle(.segmented)
            .help(layout == .list ? "Show sessions grouped by project folder" : "Show every session in one list")
        }
        ToolbarItem {
            Menu {
                Picker("Status", selection: $statusFilter) {
                    ForEach(StatusFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Filter", systemImage: statusFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .help(statusFilter == .all ? "Filter by status" : "Showing \(statusFilter.rawValue.lowercased()) sessions")
        }
        ToolbarItem {
            SecretsMenu(model: model, onRedact: requestRedact, onPurge: requestPurge)
        }
        ToolbarItemGroup {
            ArchiveButton(model: model, action: requestArchiveSelection)
            DeleteButton(model: model, action: requestDelete)
            GetInfoButton(model: model) { infoSession = model.primarySession }
            Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the transcript")
        }
    }

    private var hasActiveFilters: Bool {
        !search.isEmpty || statusFilter != .all || showsFlaggedOnly
    }

    /// Back to every session of the sidebar's choice: search, status and flagged-only off.
    private func clearFilters() {
        clearSearch()
        statusFilter = .all
        showsFlaggedOnly = false
    }

    /// "No Antigravity sessions expire soon": what the filters left out, in plain words.
    private var filteredEmptyTitle: String {
        let agent = agentFilter.map { "\($0.displayName) " } ?? ""
        if showsFlaggedOnly { return "Nothing flagged by the secret scan" }
        return switch statusFilter {
        case .all: "No \(agent)sessions"
        case .idle: "No idle \(agent)sessions"
        case .live: "No \(agent)sessions are live"
        case .expiring: "No \(agent)sessions expire soon"
        case .archived: "No archived \(agent)sessions"
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.sessions.isEmpty && !library.isLoading {
            if let error = library.errorMessage {
                ContentUnavailableView("Couldn\u{2019}t Read Sessions", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if !AppSettings.shared.settings.hiddenAgents.isEmpty {
                ContentUnavailableView("No Sessions Shown", systemImage: "eye.slash",
                                       description: Text("Some agents are hidden in Settings > Agents. The others have no sessions."))
            } else {
                ContentUnavailableView("All tidy", systemImage: "house",
                                       description: Text("No agent sessions in this home folder. The house is in order."))
            }
        } else if model.rows.isEmpty && !library.isLoading && builtRowData == rowData {
            if library.transcriptSearch.scope == .transcripts, !search.isEmpty, library.transcriptSearch.isPending(for: search) {
                TranscriptSearchPending(text: library.transcriptSearch.progressText)
            } else if !search.isEmpty {
                ContentUnavailableView {
                    Label("No Results for \u{201C}\(search)\u{201D}", systemImage: "magnifyingglass")
                } description: {
                    Text(library.transcriptSearch.scope == .transcripts
                        ? "Nothing in these transcripts matches."
                        : "No titles, projects or session IDs match. You can also search inside transcripts.")
                } actions: {
                    Button("Clear Filters", action: clearFilters)
                }
            } else {
                ContentUnavailableView {
                    Label(filteredEmptyTitle, systemImage: "line.3.horizontal.decrease.circle")
                } actions: {
                    Button("Show All Sessions", action: clearFilters)
                }
            }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = library.toast {
            UndoToast(toast: toast) {
                Task {
                    guard let action = toast.undo else { return }
                    do { try await library.undo(action) } catch { errorMessage = error.localizedDescription }
                }
            }
            .padding(.bottom, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Actions

    private func requestArchiveSelection() {
        let sessions = selectedSessions
        if sessions.count == 1 {
            guard sessions.contains(where: library.canArchive) else { return }
            requestArchive(sessions)
        } else {
            requestArchiveBatch(sessions)
        }
    }

    /// Archives what can be archived and says what was left alone.
    private func requestArchiveBatch(_ sessions: [Session]) {
        let archivable = sessions.filter(library.canArchive)
        guard !archivable.isEmpty else { return }
        var notes = library.readOnlyNotes(for: sessions)
        let writable = sessions.filter { library.readOnlyAgents[$0.agent] == nil }
        let live = writable.filter { $0.status == .live }.count
        if live > 0 { notes.append(Self.leftAlone(live, "live")) }
        let archived = writable.filter { $0.status != .live && $0.isArchived }.count
        if archived > 0 { notes.append(Self.leftAlone(archived, "already archived")) }
        let other = writable.count - archivable.count - live - archived
        if other > 0 { notes.append("\(other) \(other == 1 ? "session has" : "sessions have") no file to compress or \(other == 1 ? "is" : "are") still being changed, and \(other == 1 ? "is" : "are") left alone.") }
        requestArchive(archivable, notes: notes)
    }

    private static func leftAlone(_ n: Int, _ what: String) -> String {
        "\(n) \(what) \(n == 1 ? "session is" : "sessions are") left alone."
    }

    /// Plans first, then the confirmation sheet. Sessions with nothing to compress drop out.
    /// Opens the confirmation sheet at once; it plans the sessions while showing a spinner.
    private func requestArchive(_ sessions: [Session], notes: [String] = []) {
        let sessions = sessions.filter { library.busySessions[$0.id] == nil }
        guard !sessions.isEmpty else { return }
        archiveRequest = ArchiveRequest(sessions: sessions, notes: notes)
    }

    private func requestRedact() {
        guard let session = selectedSession, library.canRedact(session) else { return }
        Task {
            do {
                redactRequest = RedactRequest(session: session, plan: try await library.redactionPlan(for: session))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func requestPurge() {
        Task {
            do {
                purgeRequest = PurgeRequest(plan: try await library.purgePlan())
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func requestDelete() {
        requestDelete(selectedSessions)
    }

    /// Opens the confirmation sheet at once; it plans the sessions while showing a spinner.
    /// Live sessions and ones still being archived or moved are left out with a note.
    private func requestDelete(_ sessions: [Session]) {
        let candidates = sessions.filter(library.canDelete)
        guard !candidates.isEmpty else { return }
        // The Trash keeps plaintext until it is emptied; flagged sessions default to the quarantine.
        let flagged = candidates.contains { !library.findings(for: $0).isEmpty }
        var notes = library.readOnlyNotes(for: sessions)
        let live = sessions.filter { $0.status == .live && library.readOnlyAgents[$0.agent] == nil }.count
        if live > 0 { notes.append(Self.leftAlone(live, "live")) }
        let busy = sessions.filter { $0.status != .live && library.busySessions[$0.id] != nil }.count
        if busy > 0 { notes.append("\(busy) \(busy == 1 ? "session is" : "sessions are") still being archived or moved, and left alone.") }
        deleteRequest = DeleteRequest(sessions: candidates, destination: flagged ? .quarantine : AppSettings.shared.settings.deleteDestination, notes: notes)
    }
}

/// What the rows are made of: rebuilt (and formatted) only when this changes.
struct RowData: Equatable {
    /// `SessionLibrary.revision`: comparing it stands in for comparing every session.
    let revision: Int
    let findingCounts: [Session.ID: Int]
    /// `SessionLibrary.tokenRevision`.
    let tokenRevision: Int
    /// Sessions a background action works on, shown in the Status column.
    let busy: [Session.ID: String]
}

extension SessionLibrary {
    func canDelete(_ session: Session) -> Bool {
        session.status != .live && readOnlyAgents[session.agent] == nil && busySessions[session.id] == nil
    }

    /// Why Domovy only reads this session's agent, in one plain line; `nil` when it may change it.
    func readOnlyNote(for session: Session) -> String? {
        readOnlyAgents[session.agent].map { "\(session.agent.displayName) is read-only in Domovy for now: \($0)" }
    }

    /// "8 Antigravity sessions are left alone: …", one line per read-only agent in `sessions`.
    func readOnlyNotes(for sessions: [Session]) -> [String] {
        var order: [AgentKind] = []
        var counts: [AgentKind: Int] = [:]
        for session in sessions where readOnlyAgents[session.agent] != nil {
            if counts[session.agent] == nil { order.append(session.agent) }
            counts[session.agent, default: 0] += 1
        }
        return order.compactMap { agent in
            guard let n = counts[agent], let reason = readOnlyAgents[agent] else { return nil }
            return "\(n) \(agent.displayName) \(n == 1 ? "session is" : "sessions are") left alone: \(reason)"
        }
    }

    /// The read-only line shared by every session in `sessions`, when all are of read-only agents.
    func commonReadOnlyNote(for sessions: [Session]) -> String? {
        guard !sessions.isEmpty, sessions.allSatisfy({ readOnlyAgents[$0.agent] != nil }) else { return nil }
        let agents = Set(sessions.map(\.agent))
        if agents.count == 1, let first = sessions.first { return readOnlyNote(for: first) }
        return "These agents are read-only in Domovy for now: " + agents.map(\.displayName).sorted().joined(separator: ", ") + "."
    }

    func canArchive(_ session: Session) -> Bool {
        session.status != .live && !session.isArchived && session.canArchive && readOnlyAgents[session.agent] == nil
            && busySessions[session.id] == nil
    }

    func canRedact(_ session: Session) -> Bool {
        session.status != .live && findings(for: session).contains(where: \.isRedactable)
    }
}

/// One retention banner per agent whose sweep is about to take sessions.
private struct RetentionBanners: View {
    let agentFilter: AgentKind?
    @Binding var dismissed: Set<AgentKind>
    let onArchiveAll: ([Session]) -> Void
    let onReview: () -> Void

    @Environment(SessionLibrary.self) private var library

    var body: some View {
        let banners = library.expiringByAgent.filter { !dismissed.contains($0.rule.agent) && (agentFilter == nil || agentFilter == $0.rule.agent) }
        ForEach(banners, id: \.rule.agent) { banner in
            let archivable = banner.sessions.filter { !$0.isArchived }
            RetentionBanner(
                rule: banner.rule,
                sessions: banner.sessions,
                withinDays: library.expiringWithinDays(banner.sessions),
                archivableCount: banner.rule.canArchive ? archivable.count : 0,
                onArchiveAll: { onArchiveAll(archivable) },
                onReview: onReview,
                onDismiss: { dismissed.insert(banner.rule.agent) }
            )
        }
    }
}

/// The inspector: one session, a summary of several, or nothing selected.
private struct SelectionInspector: View {
    let model: SessionsTableModel
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onRedact: () -> Void

    @Environment(SessionLibrary.self) private var library

    var body: some View {
        if model.selection.count > 1 {
            SelectionSummary(
                sessions: model.selectedSessions,
                canArchive: model.selectedSessions.contains(where: library.canArchive),
                canDelete: model.selectedSessions.contains(where: library.canDelete),
                readOnlyNotes: library.readOnlyNotes(for: model.selectedSessions),
                onArchive: onArchive,
                onDelete: onDelete
            )
            .inspectorColumnWidth(min: 320, ideal: 480, max: 900)
        } else if let session = model.selectedSession {
            SessionInspector(session: session, onArchive: onArchive, onDelete: onDelete, onRedact: onRedact)
                .inspectorColumnWidth(min: 320, ideal: 480, max: 900)
        } else {
            ContentUnavailableView("No session selected", systemImage: "bubble.left.and.text.bubble.right", description: Text("Select a session to read it."))
                .inspectorColumnWidth(min: 320, ideal: 480, max: 900)
        }
    }
}

// Toolbar items that follow the selection, each its own view so a selection change redraws
// only them.

private struct SecretsMenu: View {
    let model: SessionsTableModel
    let onRedact: () -> Void
    let onPurge: () -> Void

    @Environment(SessionLibrary.self) private var library

    var body: some View {
        let count = model.selection.count
        Menu {
            Button("Scan All Sessions") { library.scanSecrets(library.sessions) }
            Button(count > 1 ? "Scan \(count) Selected Sessions" : "Scan Selected Session") {
                library.scanSecrets(model.selectedSessions)
            }
            .disabled(count == 0)
            Divider()
            Button("Redact Selected Session\u{2026}", action: onRedact)
                .disabled(!(model.selectedSession.map(library.canRedact) ?? false))
                .help("Select one idle session with findings from the secret scan")
            Button("Purge Originals\u{2026}", action: onPurge)
        } label: {
            Label("Secrets", systemImage: library.flaggedSessionCount > 0 ? "key.fill" : "key")
        }
        .help("Scan transcripts for API keys, tokens and passwords (\u{21E7}\u{2318}S)")
    }
}

private struct ArchiveButton: View {
    let model: SessionsTableModel
    let action: () -> Void

    @Environment(SessionLibrary.self) private var library

    var body: some View {
        // ⌥⌘A lives on Session > Archive…, which works with the toolbar hidden too.
        Button("Archive…", systemImage: "archivebox", action: action)
            .disabled(!model.selectedSessions.contains(where: library.canArchive))
            .help(help)
    }

    private var help: String {
        if let note = library.commonReadOnlyNote(for: model.selectedSessions) { return note }
        if model.selection.count > 1 {
            let n = model.selectedSessions.filter(library.canArchive).count
            return n == 0
                ? "None of the selected sessions can be archived: they are live, already archived or read-only."
                : "Compress \(n) of the \(model.selection.count) selected sessions on disk; the others are left alone (⌥⌘A)"
        }
        guard let session = model.selectedSession else { return "Select a session to archive it" }
        if session.status == .live { return "This session is live. Quit the \(session.agent.displayName) session using it first." }
        if session.isArchived { return "This session is already archived." }
        return "Compress this session on disk; \(session.agent.displayName) can still resume it (⌥⌘A)"
    }
}

private struct DeleteButton: View {
    let model: SessionsTableModel
    let action: () -> Void

    @Environment(SessionLibrary.self) private var library

    var body: some View {
        // ⌘⌫ lives on Session > Move to Trash….
        Button("Delete…", systemImage: "trash", action: action)
            .disabled(!model.selectedSessions.contains(where: library.canDelete))
            .help(help)
    }

    private var help: String {
        if let note = library.commonReadOnlyNote(for: model.selectedSessions) { return note }
        if model.selection.count > 1 {
            let n = model.selectedSessions.filter(library.canDelete).count
            return n == 0 ? "None of the selected sessions can be deleted: they are live or still being changed." : "Shows what \(n) selected \(n == 1 ? "session moves" : "sessions move") and where before anything changes; the others are left alone (⌘⌫)"
        }
        guard let session = model.selectedSession else { return "Select a session to delete it" }
        if session.status == .live { return "This session is live. Quit the \(session.agent.displayName) session using it first." }
        return "Shows every file that moves to the Trash or quarantine before anything changes. You can undo this. (⌘⌫)"
    }
}

private struct GetInfoButton: View {
    let model: SessionsTableModel
    let action: () -> Void

    var body: some View {
        // ⌘I lives on Session > Get Info.
        Button("Get Info", systemImage: "info.circle", action: action)
            .disabled(model.primarySession == nil)
            .help("Everything Domovy knows about this session (\u{2318}I)")
    }
}

#if DEBUG
private struct PerfHook: View {
    let handle: (PerfDriver.SessionsCommand) -> Void

    var body: some View {
        Color.clear
            .onChange(of: PerfDriver.shared.sessionsCommand) { _, command in if let command { handle(command) } }
    }
}

// Perf harness hook (App/PerfHarness.swift): lives here to reach the private state.
extension SessionsView {
    func perfHandle(_ command: PerfDriver.SessionsCommand) {
        switch command.kind {
        case .select(let ids):
            model.selection = Set(ids)
        case .sort(let column, let ascending):
            let order: SortOrder = ascending ? .forward : .reverse
            switch column {
            case "title": sortOrder = [KeyPathComparator(\SessionRow.title, order: order)]
            case "agent": sortOrder = [KeyPathComparator(\SessionRow.agentLabel, order: order)]
            case "project": sortOrder = [KeyPathComparator(\SessionRow.project, order: order)]
            case "lastActive": sortOrder = [KeyPathComparator(\SessionRow.lastActive, order: order)]
            case "size": sortOrder = [KeyPathComparator(\SessionRow.sizeBytes, order: order)]
            default: sortOrder = [KeyPathComparator(\SessionRow.statusSortKey, order: order)]
            }
        case .openDelete(let ids):
            requestDelete(allRows.filter { ids.contains($0.id) }.map(\.session))
        case .openArchive(let ids):
            let sessions = allRows.filter { ids.contains($0.id) }.map(\.session)
            if sessions.count == 1 { requestArchive(sessions) } else { requestArchiveBatch(sessions) }
        case .openInfo:
            infoSession = primarySession
        case .dismissSheets:
            deleteRequest = nil
            archiveRequest = nil
            infoSession = nil
        }
    }
}
#endif

/// Every filter narrowing the table, each with its own remove button, so a search set by
/// "Show Sessions in This Project" or a popover filter never traps the list. Escape clears all.
private struct ActiveFiltersBar: View {
    let search: String
    let statusFilter: StatusFilter
    let showsFlaggedOnly: Bool
    let onClearSearch: () -> Void
    let onClearStatus: () -> Void
    let onClearFlagged: () -> Void
    let onClearAll: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Showing only")
                .foregroundStyle(.secondary)
            if !search.isEmpty {
                FilterChip(label: "\u{201C}\(search)\u{201D}", symbol: "magnifyingglass", onRemove: onClearSearch)
                SearchScopeControl()
            }
            if statusFilter != .all {
                FilterChip(label: statusFilter.rawValue, symbol: "line.3.horizontal.decrease", onRemove: onClearStatus)
            }
            if showsFlaggedOnly {
                FilterChip(label: "Flagged", symbol: "key", onRemove: onClearFlagged)
            }
            Spacer()
            Button("Clear Filters", action: onClearAll)
                .buttonStyle(.link)
                .help("Show every session again (Escape)")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct FilterChip: View {
    let label: String
    let symbol: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(label)
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Remove filter", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Remove this filter")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .background(.quaternary, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Filter: \(label)")
        .accessibilityAction(named: "Remove Filter", onRemove)
    }
}
