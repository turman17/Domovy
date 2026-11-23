import AppKit
import DomovyCore
import SwiftUI

/// Processes: each agent's process tree with likely MCP servers, orphans on top, memory and CPU
/// refreshed every 2 seconds while visible. Freeze, Resume and Quit always go through a sheet.
struct ProcessesView: View {
    let search: String

    @Environment(SessionLibrary.self) private var library
    @Environment(ProcessMonitor.self) private var monitor
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: String?
    /// Rows the user unfolded or folded. Agents start unfolded one level, everything below folded.
    @State private var toggled: Set<String> = []
    @State private var actionRequest: ProcessActionRequest?
    @State private var errorMessage: String?

    private var rows: [ProcessRow] {
        ProcessRow.rows(monitor.report, sessionTitle: { id in library.sessions.first { $0.id == id }?.displayTitle }, search: search)
    }

    /// The tree flattened into table rows, with each row's depth, skipping folded subtrees.
    private var flat: [FlatProcessRow] {
        var result: [FlatProcessRow] = []
        func add(_ row: ProcessRow, depth: Int) {
            result.append(FlatProcessRow(row: row, depth: depth))
            guard isExpanded(row.id, depth: depth) else { return }
            for child in row.children ?? [] { add(child, depth: depth + 1) }
        }
        for row in rows { add(row, depth: 0) }
        return result
    }

    private var selectedRow: ProcessRow? { flat.first { $0.id == selection }?.row }

    private var subtitle: String {
        let report = monitor.report
        var parts = ["\(report.processCount) agent \(report.processCount == 1 ? "process" : "processes")",
                     "\(report.totalBytes.formatted(.byteCount(style: .memory))) memory"]
        if report.orphanCount > 0 { parts.append("\(report.orphanCount) orphaned") }
        if monitor.isPaused { parts.append("paused") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        table
            .overlay { emptyState }
            .overlay(alignment: .bottom) { toastOverlay }
            .navigationTitle("Processes")
            .navigationSubtitle(monitor.lastRefresh == nil ? "" : subtitle)
            .toolbar { toolbar }
            // Restarts when the window is hidden or shown again; stops when the screen goes away.
            .task(id: scenePhase) {
                guard scenePhase != .background else { return }
                await monitor.watch()
            }
            .task {
                // Debug: open a confirmation sheet for a window capture, once the list is in.
                guard let start = AppEnvironment.startProcessAction, let action = ProcessAction(rawValue: start.action) else { return }
                try? await Task.sleep(for: .seconds(3))
                request(action, [start.pid])
            }
            .sheet(item: $actionRequest) { request in
                ProcessActionSheet(request: request)
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

    private var table: some View {
        Table(flat, selection: $selection) {
            TableColumn("Process") { item in
                ProcessNameCell(item: item, isCollapsed: !isExpanded(item.id, depth: item.depth)) { toggle(item.id) }
            }
            .width(min: 220, ideal: 360)
            TableColumn("Kind") { item in
                if let node = item.row.node {
                    Text(node.kind.displayName)
                        .foregroundStyle(.secondary)
                        .help(node.kind == .mcpServer ? "Likely an MCP server, judged by its name or package. A heuristic." : "")
                }
            }
            .width(min: 70, ideal: 90)
            TableColumn("Memory") { item in
                MemoryText(bytes: item.row.totalBytes, own: item.row.node?.footprintBytes, includesChildren: !(item.row.children ?? []).isEmpty)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("CPU") { item in
                Text(item.row.cpuPercent.map { $0.formatted(.number.precision(.fractionLength(0...1))) + "%" } ?? "–")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60)
            TableColumn("State") { item in
                if let node = item.row.node { ProcessStateLabel(node: node) }
            }
            .width(min: 90, ideal: 130)
            TableColumn("") { item in
                ProcessActionsCell(row: item.row, isTopLevel: item.depth == 0, onAction: request)
            }
            .width(min: 90, ideal: 110)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let row = flat.first(where: { $0.id == id })?.row, let node = row.node {
                Button("Freeze\u{2026}") { request(.freeze, [node.pid]) }
                Button("Resume\u{2026}") { request(.resume, [node.pid]) }.disabled(!node.anyFrozen)
                Button("Quit\u{2026}") { request(.quit, [node.pid]) }.disabled(!node.isOrphan)
                Divider()
                Button("Copy PID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(node.pid), forType: .string)
                }
            }
        }
        .onDeleteCommand {
            guard let node = selectedRow?.node, node.isOrphan else { return }
            request(.quit, [node.pid])
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button(monitor.isPaused ? "Resume Updates" : "Pause Updates", systemImage: monitor.isPaused ? "play.circle" : "pause.circle") {
                monitor.isPaused.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .option])
            .help(monitor.isPaused ? "Refresh every 2 seconds again (\u{2325}\u{2318}P)" : "Keep the list as it is (\u{2325}\u{2318}P)")
            Button("Freeze\u{2026}", systemImage: "snowflake") {
                if let node = selectedRow?.node { request(node.anyFrozen ? .resume : .freeze, [node.pid]) }
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(selectedRow?.node == nil)
            .help("Freeze or resume the selected process and what it started (\u{2325}\u{2318}F)")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if monitor.isUnavailable {
            ContentUnavailableView("Processes unavailable", systemImage: "cpu", description: Text("Domovy could not read the process list."))
        } else if monitor.lastRefresh != nil, rows.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("No agent processes", systemImage: "moon.zzz", description: Text("No coding agent or local model server is running. The house is quiet."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if let toast = library.toast {
            UndoToast(toast: toast) {}
                .padding(.bottom, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func isExpanded(_ id: String, depth: Int) -> Bool {
        (depth == 0) != toggled.contains(id)
    }

    private func toggle(_ id: String) {
        if toggled.contains(id) { toggled.remove(id) } else { toggled.insert(id) }
    }

    /// Plans first, then the confirmation sheet. A refused plan still opens it, to say why.
    private func request(_ action: ProcessAction, _ pids: [Int32]) {
        do {
            actionRequest = ProcessActionRequest(plans: try pids.map { try monitor.plan(action, pid: $0) })
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct FlatProcessRow: Identifiable {
    let row: ProcessRow
    let depth: Int
    var id: String { row.id }
}

/// Disclosure chevron, symbol and name, indented by depth.
private struct ProcessNameCell: View {
    let item: FlatProcessRow
    let isCollapsed: Bool
    let onToggle: () -> Void

    private var row: ProcessRow { item.row }

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: CGFloat(item.depth) * 16, height: 1)
            if row.children?.isEmpty == false {
                Button(action: onToggle) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isCollapsed ? "Expand" : "Collapse")
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            icon
            Text(row.title)
                .fontWeight(item.depth == 0 ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            if let node = row.node {
                Text(String(node.pid))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .help("Process id \(node.pid). Started \(node.startDate.formatted(date: .abbreviated, time: .shortened)).")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var icon: some View {
        switch row.content {
        case .orphans:
            Image(systemName: "exclamationmark.circle").foregroundStyle(.tint).accessibilityHidden(true)
        case .process(let node):
            if node.kind == .agent, let agent = node.agent {
                AgentGlyph(agent: agent)
            } else {
                Image(systemName: Self.symbol(node.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
            }
        }
    }

    static func symbol(_ kind: ProcessKind) -> String {
        switch kind {
        case .agent: "cpu"
        case .helper: "square.stack.3d.up"
        case .mcpServer: "point.3.connected.trianglepath.dotted"
        case .child: "terminal"
        }
    }
}

/// Monospaced human-readable memory; exact bytes, and what the process uses itself, in the tooltip.
private struct MemoryText: View {
    let bytes: Int64
    let own: Int64?
    let includesChildren: Bool

    var body: some View {
        Text(bytes.formatted(.byteCount(style: .memory)))
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.secondary)
            .help(includesChildren
                ? "\(bytes.formatted()) bytes with the processes it started; \((own ?? 0).formatted(.byteCount(style: .memory))) itself"
                : "\(bytes.formatted()) bytes")
    }
}

/// Never color alone and never red: frozen, orphan and growing each have a symbol and a word.
struct ProcessStateLabel: View {
    let node: ProcessNode

    var body: some View {
        HStack(spacing: 8) {
            if node.isFrozen {
                Label("Frozen", systemImage: "snowflake").foregroundStyle(.secondary)
            } else if node.isOrphan {
                Label("Orphan", systemImage: "exclamationmark.circle").foregroundStyle(.tint)
                    .help("Started by an agent that is gone; nothing uses it any more.")
            } else if !node.isGrowing {
                Label("Running", systemImage: "circle").foregroundStyle(.secondary)
            }
            if node.isGrowing {
                Label("Growing", systemImage: "arrow.up.right").foregroundStyle(.tint)
                    .help(growthHelp)
            }
        }
        .lineLimit(1)
        .help(node.refusal ?? "")
    }

    private var growthHelp: String {
        guard let bytes = node.growthBytes, let interval = node.growthInterval else { return "Memory keeps growing." }
        let minutes = max(1, Int(interval / 60))
        return "Memory grew \(bytes.formatted(.byteCount(style: .memory))) in the last \(minutes) min. Freezing it stops the growth without losing anything."
    }
}

/// Freeze or Resume on an agent's row and on frozen rows; Quit on orphans; Quit All on the header.
private struct ProcessActionsCell: View {
    let row: ProcessRow
    let isTopLevel: Bool
    let onAction: (ProcessAction, [Int32]) -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            switch row.content {
            case .orphans:
                Button("Quit All\u{2026}", systemImage: "xmark") { onAction(.quit, (row.children ?? []).compactMap(\.node?.pid)) }
            case .process(let node):
                if node.isFrozen {
                    Button("Resume", systemImage: "play") { onAction(.resume, [node.pid]) }
                        .disabled(node.refusal != nil)
                } else if node.isOrphan {
                    Button("Quit\u{2026}", systemImage: "xmark") { onAction(.quit, [node.pid]) }
                } else if isTopLevel || node.isGrowing {
                    Button("Freeze", systemImage: "pause") { onAction(.freeze, [node.pid]) }
                        .disabled(node.refusal != nil)
                        .help(node.refusal ?? "Pause it and what it started; nothing is lost.")
                }
            }
        }
        .controlSize(.small)
        .labelStyle(.titleAndIcon)
    }
}
