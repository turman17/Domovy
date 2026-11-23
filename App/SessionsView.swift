import DomovyCore
import SwiftUI

/// A delete request awaiting confirmation: the session and its computed plan.
struct DeleteRequest: Identifiable {
    let session: Session
    let plan: Plan
    var id: String { session.id }
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
    @State private var selection: Session.ID? = AppEnvironment.startSelection
    @State private var statusFilter: StatusFilter = .all
    @State private var sortOrder = [KeyPathComparator(\Session.lastActive, order: .reverse)]
    @State private var showInspector = true
    @State private var dismissedBanners: Set<AgentKind> = []
    @State private var deleteRequest: DeleteRequest?
    @State private var archiveRequest: ArchiveRequest?
    @State private var previewSession: Session?
    @State private var redactRequest: RedactRequest?
    @State private var purgeRequest: PurgeRequest?
    @State private var showsFlaggedOnly = false
    @State private var errorMessage: String?

    private var visible: [Session] {
        library.sessions
            .filter { agentFilter == nil || $0.agent == agentFilter }
            .filter { statusFilter.matches($0) }
            .filter { !showsFlaggedOnly || !library.findings(for: $0).isEmpty }
            .filter {
                search.isEmpty
                    || $0.displayTitle.localizedCaseInsensitiveContains(search)
                    || ($0.projectName ?? "").localizedCaseInsensitiveContains(search)
            }
            .sorted(using: sortOrder)
    }

    private var selectedSession: Session? {
        library.sessions.first { $0.id == selection }
    }

    private var canDeleteSelection: Bool {
        guard let selectedSession else { return false }
        return selectedSession.status != .live
    }

    private var canArchiveSelection: Bool {
        guard let selectedSession else { return false }
        return selectedSession.status != .live && !selectedSession.isArchived && library.readOnlyAgents[selectedSession.agent] == nil
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
        .navigationSubtitle("\(visible.count) \(visible.count == 1 ? "session" : "sessions") · \(visible.reduce(0) { $0 + $1.sizeBytes }.formatted(.byteCount(style: .file)))")
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            if let selectedSession {
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
        Table(visible, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Title", value: \.displayTitle) { Text($0.displayTitle).lineLimit(1) }
                .width(min: 180, ideal: 320)
            TableColumn("Agent", value: \.agentLabel) { session in
                HStack(spacing: 6) {
                    AgentGlyph(agent: session.agent)
                    Text(session.agentLabel)
                        .lineLimit(1)
                }
                .help(session.desktopHelp ?? session.agent.displayName)
            }
            .width(min: 100, ideal: 150)
            TableColumn("Project", value: \.sortProject) { Text($0.projectName ?? "—").foregroundStyle(.secondary) }
                .width(min: 80, ideal: 100)
            TableColumn("Last active", value: \.lastActive) { RelativeDateText(date: $0.lastActive).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 100)
            TableColumn("Size", value: \.sizeBytes) { session in
                SizeText(bytes: session.sizeBytes)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 70)
            TableColumn("Status", value: \.status.rawValue) { session in
                HStack(spacing: 6) {
                    StatusLabel(session: session)
                    SecretMarker(count: library.findings(for: session).count)
                }
            }
            .width(min: 96, ideal: 116)
        }
        .onDeleteCommand(perform: requestDelete)
        .onKeyPress(.space) {
            guard let selectedSession else { return .ignored }
            previewSession = selectedSession
            return .handled
        }
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
                Button("Scan Selected Session") {
                    if let selectedSession { library.scanSecrets([selectedSession]) }
                }
                .disabled(selectedSession == nil)
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
        guard let selectedSession else { return "Select a session to archive it" }
        if selectedSession.status == .live { return "This session is live. Quit the Claude Code session using it first." }
        if selectedSession.isArchived { return "This session is already archived." }
        return "Compress this session on disk; Claude Code can still resume it (⌥⌘A)"
    }

    private var deleteHelp: String {
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
        } else if visible.isEmpty && !library.isLoading {
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
        guard let session = selectedSession, canArchiveSelection else { return }
        requestArchive([session])
    }

    /// Plans first, then the confirmation sheet. Sessions with nothing to compress drop out.
    private func requestArchive(_ sessions: [Session]) {
        Task {
            do {
                let plans = try await library.archivePlans(for: sessions)
                guard !plans.isEmpty else {
                    errorMessage = sessions.count == 1 && sessions[0].agent == .codex
                        ? "Nothing to archive: this session is already in Codex's archive or has nothing to compress."
                        : "Nothing to compress: \(sessions.count == 1 ? "this session's files are" : "these sessions' files are") already compressed or too small to gain from it."
                    return
                }
                let planned = Set(plans.map(\.sessionID))
                archiveRequest = ArchiveRequest(sessions: sessions.filter { planned.contains($0.id) }, plans: plans)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
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
        guard let session = selectedSession, session.status != .live else { return }
        // The Trash keeps plaintext until it is emptied; flagged sessions default to the quarantine.
        let destination: Destination = library.findings(for: session).isEmpty ? .trash : .quarantine
        Task {
            do {
                let plan = try await library.deletePlan(for: session, destination: destination)
                deleteRequest = DeleteRequest(session: session, plan: plan)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
