import AppKit
import DomovyCore
import SwiftUI

/// Disk: where every agent's bytes are, each category marked safe / consequences / keep.
/// Rows reveal files in Finder or lead to the Sessions list; orphans and duplicates have a
/// cleanup plan of their own.
struct DiskView: View {
    /// Switches the sidebar to Sessions, filtered by this agent.
    let onOpenSessions: (AgentKind) -> Void

    @Environment(SessionLibrary.self) private var library
    @State private var orphanRequest: OrphanRequest?
    @State private var cleanupRequest: CleanupRequest?
    @State private var modelRequest: ModelRemovalRequest?
    @State private var purgeRequest: PurgeRequest?
    @State private var errorMessage: String?
    /// Local models ticked for "Remove Selected…", by `LocalModel.id`.
    @State private var selectedModels: Set<String> = []
    @AppStorage("unusedModelDays") private var unusedDays = 60

    /// Largest agent first, matching the breakdown bar and its legend.
    private var ordered: [Footprint] {
        library.footprints.sorted { $0.totalBytes > $1.totalBytes }
    }

    private var selection: ModelSelection {
        ModelSelection(selected: $selectedModels, unusedDays: unusedDays, onRemove: { requestModelRemoval([$0]) })
    }

    private var subtitle: String {
        let total = library.totalFootprintBytes.formatted(.byteCount(style: .file))
        let safe = library.safeFootprintBytes.formatted(.byteCount(style: .file))
        let models = library.localModelBytes
        let modelText = models > 0 ? " · \(models.formatted(.byteCount(style: .file))) of it local models" : ""
        return "\(total) used by AI agents\(modelText) · \(safe) safe to remove"
    }

    var body: some View {
        Group {
            if library.footprints.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        breakdown
                        if !library.orphanReport.isEmpty {
                            OrphansSection(report: library.orphanReport, onCleanUp: requestCleanUp)
                        }
                        ForEach(ordered.filter { !$0.agent.isModelStore }, id: \.agent) { footprint in
                            AgentFootprintSection(footprint: footprint, onOpenSessions: onOpenSessions, onCleanUp: { requestCleanUp(.orphans) }, onGuidedCleanup: requestCleanup)
                        }
                        if !library.modelFootprints.isEmpty {
                            LocalModelsHeader(unusedDays: $unusedDays, selected: $selectedModels, onRemoveSelected: removeSelected, onPurgeCopies: requestPurge)
                                .id(LocalModelsHeader.anchor)
                            ForEach(library.modelFootprints, id: \.agent) { footprint in
                                AgentFootprintSection(footprint: footprint, models: selection, onOpenSessions: onOpenSessions,
                                                      onCleanUp: { requestCleanUp(.orphans) }, onGuidedCleanup: requestCleanup)
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                .task(id: library.requestedDiskAnchor) {
                    guard let anchor = library.requestedDiskAnchor else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                    library.requestedDiskAnchor = nil
                }
                }
            }
        }
        .navigationTitle("Disk")
        .navigationSubtitle(library.footprints.isEmpty ? "" : subtitle)
        .overlay(alignment: .bottom) { toastOverlay }
        .sheet(item: $orphanRequest) { request in
            OrphanPlanSheet(request: request)
        }
        .sheet(item: $cleanupRequest) { request in
            CleanupPlanSheet(request: request)
        }
        .sheet(item: $modelRequest) { request in
            ModelRemovalSheet(request: request)
        }
        .sheet(item: $purgeRequest) { request in
            PurgeSheet(plan: request.plan)
        }
        .onChange(of: library.footprints) { _, _ in
            // Models removed since are no longer selectable.
            selectedModels.formIntersection(library.localModels.map(\.id))
        }
        .task(id: library.footprints.isEmpty) {
            // Debug only: DOMOVY_OPEN_CLEANUP=<id> opens that cleanup's sheet for a window capture;
            // a model id (ollama:qwen3:14b) or "unused-models" opens the model removal sheet.
            guard let raw = AppEnvironment.startCleanupRaw, !library.footprints.isEmpty, cleanupRequest == nil, modelRequest == nil else { return }
            try? await Task.sleep(for: .seconds(1))
            NSApp.activate()
            if let id = CleanupID(rawValue: raw) {
                requestCleanup(id)
            } else if raw == "unused-models" {
                selectedModels = Set(library.unusedModels(days: unusedDays).map(\.id))
                removeSelected()
            } else {
                let ids = Set(raw.split(separator: ",").map(String.init))
                requestModelRemoval(library.localModels.filter { ids.contains($0.id) })
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task(id: library.toast?.id) {
            guard library.toast != nil else { return }
            try? await Task.sleep(for: .seconds(8))
            withAnimation { library.toast = nil }
        }
    }

    /// Plans first, then the confirmation sheet. A blocked plan still opens it, to say why.
    private func requestCleanup(_ id: CleanupID) {
        Task {
            do {
                cleanupRequest = CleanupRequest(cleanup: try await library.cleanupPlan(id, destination: .trash))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// The copies kept before tools deleted models; the sheet names each one first.
    private func requestPurge() {
        Task {
            do {
                purgeRequest = PurgeRequest(plan: try await library.purgePlan([.toolCopy]))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeSelected() {
        requestModelRemoval(library.localModels.filter { selectedModels.contains($0.id) })
    }

    /// Plans first, then the confirmation sheet. A blocked plan still opens it, to say why.
    private func requestModelRemoval(_ models: [LocalModel]) {
        guard !models.isEmpty else { return }
        Task {
            do {
                modelRequest = ModelRemovalRequest(removal: try await library.modelRemovalPlan(models, destination: .trash))
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Plans first, then the confirmation sheet.
    private func requestCleanUp(_ scope: OrphanScope) {
        Task {
            do {
                let plan = try await library.orphanPlan(scope, destination: .trash)
                guard !plan.isEmpty else {
                    errorMessage = plan.remarks.first ?? "Nothing to clean up: \(scope == .orphans ? library.orphanReport.orphanSummary : library.orphanReport.duplicateSummary)"
                    return
                }
                orphanRequest = OrphanRequest(scope: scope, plan: plan)
            } catch {
                errorMessage = error.localizedDescription
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

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            BreakdownBar(segments: ordered.map { ($0.agent.displayName, $0.totalBytes) }, height: 10)
            HStack(spacing: 16) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { index, footprint in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(BreakdownBar.color(at: index))
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(footprint.agent.displayName)
                        SizeText(bytes: footprint.totalBytes)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                }
            }
            .font(.callout)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if library.isLoading {
            ProgressView("Measuring agent folders…")
        } else {
            ContentUnavailableView(
                "No agent folders found",
                systemImage: "internaldrive",
                description: Text("Domovy looked for Claude Code, Claude Desktop, Codex, Cursor and local model stores and found none. The house is in order.")
            )
        }
    }
}

/// One agent: glyph, name and total, then its categories in a rounded box.
private struct AgentFootprintSection: View {
    let footprint: Footprint
    /// Set for local model stores: rows get a checkbox and their date.
    var models: ModelSelection?
    let onOpenSessions: (AgentKind) -> Void
    let onCleanUp: () -> Void
    let onGuidedCleanup: (CleanupID) -> Void

    /// Removable categories first, largest first; what the agent needs comes last.
    private var rows: [Footprint.Category] {
        footprint.categories.sorted {
            ($0.disposition == .keep ? 1 : 0, -$0.sizeBytes) < ($1.disposition == .keep ? 1 : 0, -$1.sizeBytes)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AgentGlyph(agent: footprint.agent)
                Text(footprint.agent.displayName)
                    .foregroundStyle(.secondary)
                Spacer()
                SizeText(bytes: footprint.totalBytes)
                    .font(.system(.callout, design: .monospaced))
            }
            .help(footprint.root.path)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, category in
                    if index > 0 { Divider() }
                    CategoryRow(category: category, agent: footprint.agent, model: footprint.model(for: category), selection: models,
                                onOpenSessions: onOpenSessions, onCleanUp: onCleanUp, onGuidedCleanup: onGuidedCleanup)
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }
}

private struct CategoryRow: View {
    let category: Footprint.Category
    let agent: AgentKind
    /// The local model this row stands for, if any.
    var model: LocalModel?
    var selection: ModelSelection?
    let onOpenSessions: (AgentKind) -> Void
    let onCleanUp: () -> Void
    let onGuidedCleanup: (CleanupID) -> Void

    private var instructions: String? {
        if case .instructions(let text) = category.guidance { return text }
        return nil
    }

    var body: some View {
        HStack(spacing: 16) {
            if let selection {
                Toggle(isOn: selection.binding(for: model)) { EmptyView() }
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(model == nil)
                    .opacity(model == nil ? 0 : 1)
                    .accessibilityLabel("Select \(category.name)")
                    .accessibilityHidden(model == nil)
            }
            DispositionBadge(disposition: category.disposition)
                .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .fontWeight(.semibold)
                Text(category.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let model, let selection {
                    ModelDateLine(model: model, unusedDays: selection.unusedDays)
                }
                if let instructions {
                    Label(instructions, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(category.sizeBytes.formatted(.byteCount(style: .file)))
                .font(.system(.callout, design: .monospaced))
                .help(sizeTooltip)
            actionButton
                .frame(minWidth: 116, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show in Finder", action: reveal)
            if category.guidance == .manageInSessions {
                Button("Open Sessions") { onOpenSessions(agent) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actionButton: some View {
        if let model, let selection {
            Button("Remove\u{2026}") { selection.onRemove(model) }
                .help(model.agent == .lmStudio ? "Shows every file first. Moves the folder to the Trash; you can undo this."
                      : "Shows exactly what happens first. \(model.agent.displayName)'s own command deletes it when it is available; Domovy keeps a copy so you can undo.")
        } else if let id = category.cleanupID {
            guidedButton(id)
        } else if category.guidance == .manageInSessions {
            Button("Open Sessions") { onOpenSessions(agent) }
                .help("Delete or archive \(agent.displayName) sessions one by one")
        } else if category.guidance == .cleanUpOrphans {
            Button("Clean Up\u{2026}", action: onCleanUp)
                .buttonStyle(.borderedProminent)
                .help("Shows every folder first. Moves them to the Trash; you can undo this.")
        } else {
            Button("Show in Finder", action: reveal)
                .help((category.url.path as NSString).abbreviatingWithTildeInPath)
        }
    }

    /// Accent for safe rows; consequences rows get a plain button, and their sheet the red one.
    @ViewBuilder
    private func guidedButton(_ id: CleanupID) -> some View {
        let button = Button(id.buttonTitle) { onGuidedCleanup(id) }
            .help(id.compresses ? "Shows every file first. Compresses them in place; you can undo this." : "Shows every item first. Moves them to the Trash; you can undo this.")
        if category.disposition == .safe {
            button.buttonStyle(.borderedProminent)
        } else {
            button
        }
    }

    private var sizeTooltip: String {
        let onDisk = "\(category.sizeBytes.formatted()) bytes on disk"
        guard category.logicalBytes != category.sizeBytes else { return onDisk }
        return onDisk + " · \(category.logicalBytes.formatted()) bytes of content"
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting(category.revealURLs)
    }
}

/// Never color alone: symbol + word, tinted. Green safe, accent consequences, gray keep.
struct DispositionBadge: View {
    let disposition: Footprint.Disposition

    private var symbol: String {
        switch disposition {
        case .safe: "checkmark.circle"
        case .consequences: "exclamationmark.circle"
        case .keep: "lock"
        }
    }

    private var color: Color {
        switch disposition {
        case .safe: .green
        case .consequences: .accentColor
        case .keep: .secondary
        }
    }

    var body: some View {
        Label(disposition.displayName, systemImage: symbol)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}
