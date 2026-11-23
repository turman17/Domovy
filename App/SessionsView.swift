import DomovyCore
import SwiftUI

/// A delete request awaiting confirmation: the sessions and one computed plan each.
struct DeleteRequest: Identifiable {
    let id = UUID()
    let sessions: [Session]
    let plans: [Plan]
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
    @State private var selection: Set<Session.ID> = Set([AppEnvironment.startSelection].compactMap { $0 })
    @State private var statusFilter: StatusFilter = .all
    @State private var sortOrder = [KeyPathComparator(\SessionRow.lastActive, order: .reverse)]
    /// Column widths, kept here so they survive the table being rebuilt on a sort.
    @State private var columns = TableColumnCustomization<SessionRow>()
    @State private var showInspector = true
    @State private var dismissedBanners: Set<AgentKind> = []
    @State private var deleteRequest: DeleteRequest?
    @State private var archiveRequest: ArchiveRequest?
    @State private var previewSession: Session?
    @State private var infoSession: Session?
    @State private var redactRequest: RedactRequest?
    @State private var purgeRequest: PurgeRequest?
    @State private var showsFlaggedOnly = false
    @State private var errorMessage: String?

    /// Every session as a row, text formatted once per reload or scan, so scrolling draws
    /// cells without formatting and sorting only reorders.
    @State private var allRows: [SessionRow] = []
    /// `allRows` filtered and sorted for the table.
    @State private var rows: [SessionRow] = []

    private var rowData: RowData {
        RowData(sessions: library.sessions, findingCounts: library.secretFindings.mapValues(\.count))
    }

    private var rowView: RowView {
        RowView(
            agentFilter: agentFilter,
            statusFilter: statusFilter,
            showsFlaggedOnly: showsFlaggedOnly,
            search: search,
            sortOrder: sortOrder
        )
    }

    /// Selected sessions in table order.
    private var selectedSessions: [Session] {
        guard !selection.isEmpty else { return [] }
        return rows.lazy.filter { selection.contains($0.id) }.map(\.session)
    }

    /// The one selected session, or nil when none or several are selected.
    private var selectedSession: Session? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return library.sessions.first { $0.id == id }
    }

    /// What Quick Look, Get Info and scrolling use: the first selected row.
    private var primarySession: Session? {
        selectedSession ?? selectedSessions.first
    }

    private var canDeleteSelection: Bool {
        selectedSessions.contains(where: canDelete)
    }

    private func canDelete(_ session: Session) -> Bool {
        session.status != .live && library.busySessions[session.id] == nil
    }

    private var canArchiveSelection: Bool {
        selectedSessions.contains(where: canArchive)
    }

    private func canArchive(_ session: Session) -> Bool {
        session.status != .live && !session.isArchived && session.canArchive && library.readOnlyAgents[session.agent] == nil
            && library.busySessions[session.id] == nil
    }

    /// One retention banner per agent whose sweep is about to take sessions.
    private var banners: [(rule: RetentionRule, sessions: [Session])] {
        library.expiringByAgent.filter { !dismissedBanners.contains($0.rule.agent) && (agentFilter == nil || agentFilter == $0.rule.agent) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(banners, id: \.rule.agent) { banner in
                let archivable = banner.sessions.filter { !$0.isArchived }
                RetentionBanner(
                    rule: banner.rule,
                    sessions: banner.sessions,
                    withinDays: library.expiringWithinDays(banner.sessions),
                    archivableCount: banner.rule.canArchive ? archivable.count : 0,
                    onArchiveAll: { requestArchive(archivable) },
                    onReview: { statusFilter = .expiring },
                    onDismiss: { dismissedBanners.insert(banner.rule.agent) }
                )
            }
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
            table
        }
        .overlay { emptyState }
        .overlay(alignment: .bottom) { toastOverlay }
        .navigationTitle(showsFlaggedOnly ? "Flagged by the secret scan" : statusFilter == .expiring ? "Expiring soon" : (agentFilter?.displayName ?? "Sessions"))
        .navigationSubtitle("\(rows.count) \(rows.count == 1 ? "session" : "sessions") · \(rows.reduce(0) { $0 + $1.sizeBytes }.formatted(.byteCount(style: .file)))")
        .onChange(of: rowData, initial: true) { _, data in
            allRows = data.sessions.map { SessionRow($0, secretCount: data.findingCounts[$0.id] ?? 0) }
            rows = rowView.apply(to: allRows)
        }
        .onChange(of: rowView) { _, view in rows = view.apply(to: allRows) }
        .onChange(of: library.sessions.isEmpty) { _, isEmpty in
            if !isEmpty, AppEnvironment.opensInfoAtLaunch, infoSession == nil { infoSession = primarySession }
        }
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            if selection.count > 1 {
                SelectionSummary(
                    sessions: selectedSessions,
                    canArchive: canArchiveSelection,
                    canDelete: canDeleteSelection,
                    onArchive: requestArchiveSelection,
                    onDelete: requestDelete
                )
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            } else if let selectedSession {
                SessionInspector(session: selectedSession, onArchive: requestArchiveSelection, onDelete: requestDelete, onRedact: requestRedact)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            } else {
                ContentUnavailableView("No session selected", systemImage: "bubble.left.and.text.bubble.right", description: Text("Select a session to read it."))
            }
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
        .onChange(of: library.requestedFilter) { _, requested in
            if let requested {
                statusFilter = requested
                library.requestedFilter = nil
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
        ScrollViewReader { proxy in
            sessionsTable
                // A new sort rebuilds the table: letting it animate every row to its new
                // place takes AppKit seconds with hundreds of rows.
                .id(sortOrder.map { "\($0.keyPath)\($0.order == .forward)" })
                .onChange(of: sortOrder) {
                    guard let first = primarySession?.id else { return }
                    Task { proxy.scrollTo(first, anchor: .center) }
                }
        }
    }

    private var sessionsTable: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columns) {
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
            .width(min: 60, ideal: 70)
            .customizationID("size")
            TableColumn("Status", value: \.statusSortKey) { row in
                HStack(spacing: 6) {
                    if let status = library.busySessions[row.id] {
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
        }
        .contextMenu(forSelectionType: Session.ID.self) { ids in
            // Right-clicking inside a selection gives the whole selection, like the Finder.
            if ids.count > 1 {
                selectionMenu(for: rows.filter { ids.contains($0.id) }.map(\.session))
            } else if let id = ids.first, let session = library.sessions.first(where: { $0.id == id }) {
                rowMenu(for: session)
            }
        } primaryAction: { ids in
            if let session = rows.first(where: { ids.contains($0.id) })?.session { previewSession = session }
        }
        .onDeleteCommand(perform: requestDelete)
        .onKeyPress(.space) {
            guard let primarySession else { return .ignored }
            previewSession = primarySession
            return .handled
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
        if let command = resumeCommand(for: session) {
            Button("Copy Resume Command", systemImage: "terminal") { copyToPasteboard(command) }
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
        Button("Scan for Secrets", systemImage: "key") { library.scanSecrets([session]) }
        Divider()
        Button("Archive\u{2026}", systemImage: "archivebox") {
            selection = [session.id]
            requestArchive([session])
        }
        .disabled(!canArchive(session))
        Button("Move to Trash\u{2026}", systemImage: "trash") {
            selection = [session.id]
            requestDelete([session])
        }
        .disabled(!canDelete(session))
    }

    /// Right-click menu on several rows: actions that make sense for all of them at once.
    @ViewBuilder
    private func selectionMenu(for sessions: [Session]) -> some View {
        let n = sessions.count
        Button("Copy Session IDs", systemImage: "number") {
            copyToPasteboard(sessions.map(\.id).joined(separator: "\n"))
        }
        Button("Scan \(n) for Secrets", systemImage: "key") { library.scanSecrets(sessions) }
        Divider()
        Button("Archive \(n) Sessions\u{2026}", systemImage: "archivebox") { requestArchiveBatch(sessions) }
            .disabled(!sessions.contains(where: canArchive))
        Button("Move \(n) Sessions to Trash\u{2026}", systemImage: "trash") { requestDelete(sessions) }
            .disabled(!sessions.contains(where: canDelete))
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if AppEnvironment.isDevHome {
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
            Menu {
                Button("Scan All Sessions") { library.scanSecrets(library.sessions) }
                Button(selection.count > 1 ? "Scan \(selection.count) Selected Sessions" : "Scan Selected Session") {
                    library.scanSecrets(selectedSessions)
                }
                .disabled(selection.isEmpty)
                Divider()
                Button("Redact Selected Session\u{2026}", action: requestRedact)
                    .disabled(!canRedactSelection)
                Button("Purge Originals\u{2026}", action: requestPurge)
            } label: {
                Label("Secrets", systemImage: library.flaggedSessionCount > 0 ? "key.fill" : "key")
            }
            .help("Scan transcripts for API keys, tokens and passwords (\u{21E7}\u{2318}S)")
        }
        ToolbarItemGroup {
            Button("Archive…", systemImage: "archivebox", action: requestArchiveSelection)
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(!canArchiveSelection)
                .help(archiveHelp)
            Button("Delete…", systemImage: "trash", action: requestDelete)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(!canDeleteSelection)
                .help(deleteHelp)
            Button("Get Info", systemImage: "info.circle") { infoSession = primarySession }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(primarySession == nil)
                .help("Everything Domovy knows about this session (\u{2318}I)")
            Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help("Show or hide the transcript")
        }
    }

    private var canRedactSelection: Bool {
        guard let selectedSession, selectedSession.status != .live else { return false }
        return library.findings(for: selectedSession).contains(where: \.isRedactable)
    }

    private var archiveHelp: String {
        if selection.count > 1 {
            let n = selectedSessions.filter(canArchive).count
            return n == 0
                ? "None of the selected sessions can be archived: they are live, already archived or read-only."
                : "Compress \(n) of the \(selection.count) selected sessions on disk; the others are left alone (⌥⌘A)"
        }
        guard let selectedSession else { return "Select a session to archive it" }
        if selectedSession.status == .live { return "This session is live. Quit the Claude Code session using it first." }
        if selectedSession.isArchived { return "This session is already archived." }
        return "Compress this session on disk; Claude Code can still resume it (⌥⌘A)"
    }

    private var deleteHelp: String {
        if selection.count > 1 {
            let n = selectedSessions.filter { $0.status != .live }.count
            return n == 0 ? "All selected sessions are live." : "Move \(n) selected \(n == 1 ? "session" : "sessions") to the Trash; live ones are left alone (⌘⌫)"
        }
        guard let selectedSession else { return "Select a session to delete it" }
        if selectedSession.status == .live { return "This session is live. Quit the Claude Code session using it first." }
        return "Move this session to the Trash (⌘⌫)"
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.sessions.isEmpty && !library.isLoading {
            ContentUnavailableView(
                "All tidy",
                systemImage: "house",
                description: Text(library.errorMessage ?? "No agent sessions in this home folder. The house is in order.")
            )
        } else if rows.isEmpty && !library.isLoading {
            ContentUnavailableView.search(text: search.isEmpty ? statusFilter.rawValue : search)
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
            guard canArchiveSelection else { return }
            requestArchive(sessions)
        } else {
            requestArchiveBatch(sessions)
        }
    }

    /// Archives what can be archived and says what was left alone.
    private func requestArchiveBatch(_ sessions: [Session]) {
        let archivable = sessions.filter(canArchive)
        guard !archivable.isEmpty else { return }
        var notes: [String] = []
        let live = sessions.filter { $0.status == .live }.count
        if live > 0 { notes.append(Self.leftAlone(live, "live")) }
        let archived = sessions.filter { $0.status != .live && $0.isArchived }.count
        if archived > 0 { notes.append(Self.leftAlone(archived, "already archived")) }
        let other = sessions.count - archivable.count - live - archived
        if other > 0 { notes.append("\(other) \(other == 1 ? "session" : "sessions") from a read-only agent or with nothing to compress \(other == 1 ? "is" : "are") left alone.") }
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
        guard let session = selectedSession, canRedactSelection else { return }
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

    /// Plans first, then one confirmation sheet. In a batch, live sessions and sessions that
    /// cannot be planned are left out and the sheet says so; a single one shows why instead.
    private func requestDelete(_ sessions: [Session]) {
        let candidates = sessions.filter(canDelete)
        guard !candidates.isEmpty else { return }
        // The Trash keeps plaintext until it is emptied; flagged sessions default to the quarantine.
        let flagged = candidates.contains { !library.findings(for: $0).isEmpty }
        let destination: Destination = flagged ? .quarantine : .trash
        Task {
            if candidates.count == 1, sessions.count == 1 {
                do {
                    let plan = try await library.deletePlan(for: candidates[0], destination: destination)
                    deleteRequest = DeleteRequest(sessions: candidates, plans: [plan])
                } catch {
                    errorMessage = error.localizedDescription
                }
                return
            }
            var planned: [Session] = []
            var plans: [Plan] = []
            var live = sessions.filter { $0.status == .live }.count
            let busy = sessions.filter { library.busySessions[$0.id] != nil }.count
            var failed = 0
            for session in candidates {
                do {
                    let plan = try await library.deletePlan(for: session, destination: destination)
                    if plan.liveCheck.isLive { live += 1; continue }
                    if plan.isEmpty { failed += 1; continue }
                    planned.append(session)
                    plans.append(plan)
                } catch {
                    failed += 1
                }
            }
            var notes: [String] = []
            if live > 0 { notes.append(Self.leftAlone(live, "live")) }
            if busy > 0 { notes.append("\(busy) \(busy == 1 ? "session is" : "sessions are") still being archived or moved, and left alone.") }
            if failed > 0 { notes.append("\(failed) \(failed == 1 ? "session" : "sessions") could not be planned and \(failed == 1 ? "is" : "are") left alone; delete \(failed == 1 ? "it" : "them") one at a time to see why.") }
            guard !plans.isEmpty else {
                errorMessage = "None of the selected sessions can be deleted right now. " + notes.joined(separator: " ")
                return
            }
            deleteRequest = DeleteRequest(sessions: planned, plans: plans, notes: notes)
        }
    }
}

/// What the rows are made of: rebuilt (and formatted) only when this changes.
struct RowData: Equatable {
    let sessions: [Session]
    let findingCounts: [Session.ID: Int]
}

/// How the rows are shown: changing it filters and sorts the formatted rows again.
struct RowView: Equatable {
    let agentFilter: AgentKind?
    let statusFilter: StatusFilter
    let showsFlaggedOnly: Bool
    let search: String
    let sortOrder: [KeyPathComparator<SessionRow>]

    func apply(to rows: [SessionRow]) -> [SessionRow] {
        rows
            .filter { row in
                let session = row.session
                return (agentFilter == nil || session.agent == agentFilter)
                    && statusFilter.matches(session)
                    && (!showsFlaggedOnly || row.secretCount > 0)
                    && (search.isEmpty
                        || row.title.localizedCaseInsensitiveContains(search)
                        || row.project.localizedCaseInsensitiveContains(search))
            }
            .sorted(using: sortOrder)
    }
}

/// One sessions-table row with its text formatted up front: cells only read strings.
struct SessionRow: Identifiable, Equatable {
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

    var id: Session.ID { session.id }
    var memberCount: Int { session.memberCount }

    init(_ session: Session, secretCount: Int) {
        self.session = session
        title = session.displayTitle
        agentLabel = session.agentLabel
        agentHelp = session.desktopHelp ?? session.agent.displayName
        project = session.sortProject
        lastActive = session.lastActive
        relativeDate = session.lastActive.formatted(.relative(presentation: .named))
        absoluteDate = session.lastActive.formatted(date: .abbreviated, time: .shortened)
        sizeBytes = session.sizeBytes
        sizeText = session.sizeBytes.formatted(.byteCount(style: .file))
        exactBytes = "\(session.sizeBytes.formatted()) bytes"
        statusSortKey = session.status.rawValue
        self.secretCount = secretCount
    }
}
