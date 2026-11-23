import DomovyCore
import SwiftUI

/// A delete request awaiting confirmation: the session and its computed plan.
struct DeleteRequest: Identifiable {
    let session: Session
    let plan: Plan
    var id: String { session.id }
}

struct SessionsView: View {
    let agentFilter: AgentKind?
    /// Owned by ContentView: `.searchable` must sit on the split view, or SwiftUI can insert
    /// its search toolbar item twice and AppKit aborts the window update.
    let search: String

    @Environment(SessionLibrary.self) private var library
    @State private var selection: Session.ID?
    @State private var statusFilter: StatusFilter = .all
    @State private var sortOrder = [KeyPathComparator(\Session.lastActive, order: .reverse)]
    @State private var showInspector = true
    @State private var bannerDismissed = false
    @State private var deleteRequest: DeleteRequest?
    @State private var archiveRequest: ArchiveRequest?
    @State private var previewSession: Session?
    @State private var errorMessage: String?

    private var visible: [Session] {
        library.sessions
            .filter { agentFilter == nil || $0.agent == agentFilter }
            .filter { statusFilter.matches($0) }
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
        return selectedSession.status != .live && !selectedSession.isArchived
    }

    /// Expiring sessions "Archive all" would compress.
    private var archivableExpiring: [Session] {
        library.expiringSessions.filter { !$0.isArchived }
    }

    private var showsBanner: Bool {
        !bannerDismissed && !library.expiringSessions.isEmpty && (agentFilter == nil || agentFilter == .claudeCode)
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsBanner {
                RetentionBanner(
                    sessions: library.expiringSessions,
                    retentionDays: library.retentionDays,
                    withinDays: library.expiringWithinDays,
                    settingsURL: library.adapter.root.appendingPathComponent("settings.json"),
                    archivableCount: archivableExpiring.count,
                    onArchiveAll: { requestArchive(archivableExpiring) },
                    onReview: { statusFilter = .expiring },
                    onDismiss: { bannerDismissed = true }
                )
            }
            table
        }
        .overlay { emptyState }
        .overlay(alignment: .bottom) { toastOverlay }
        .navigationTitle(statusFilter == .expiring ? "Expiring soon" : (agentFilter?.displayName ?? "Sessions"))
        .navigationSubtitle("\(visible.count) \(visible.count == 1 ? "session" : "sessions") · \(visible.reduce(0) { $0 + $1.sizeBytes }.formatted(.byteCount(style: .file)))")
        .toolbar { toolbar }
        .inspector(isPresented: $showInspector) {
            if let selectedSession {
                SessionInspector(session: selectedSession, onArchive: requestArchiveSelection, onDelete: requestDelete)
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
            TableColumn("Agent", value: \.agent.displayName) { session in
                HStack(spacing: 6) {
                    AgentGlyph(agent: session.agent)
                    Text(session.agent.displayName)
                }
            }
            .width(min: 100, ideal: 120)
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
            TableColumn("Status", value: \.status.rawValue) { StatusLabel(session: $0) }
                .width(min: 80, ideal: 96)
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
                    errorMessage = "Nothing to compress: \(sessions.count == 1 ? "this session's files are" : "these sessions' files are") already compressed or too small to gain from it."
                    return
                }
                let planned = Set(plans.map(\.sessionID))
                archiveRequest = ArchiveRequest(sessions: sessions.filter { planned.contains($0.id) }, plans: plans)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func requestDelete() {
        guard let session = selectedSession, session.status != .live else { return }
        Task {
            do {
                let plan = try await library.deletePlan(for: session, destination: .trash)
                deleteRequest = DeleteRequest(session: session, plan: plan)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
