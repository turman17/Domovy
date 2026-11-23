import DomovyCore
import SwiftUI

/// Menu bar popover: total footprint, breakdown by agent, what needs attention, Open Domovy.
struct MenuBarView: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(ProcessMonitor.self) private var processes
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(alignment: .leading, spacing: 2) {
                Text(library.totalFootprintBytes.formatted(.byteCount(style: .file)))
                    .font(.system(size: 28, weight: .bold))
                    .monospacedDigit()
                Text("used by AI agents on this Mac")
                    .foregroundStyle(.secondary)
            }
            breakdown
            Divider()
            if library.needsAttention || !library.liveSessions.isEmpty || processes.needsAttention {
                attention
            } else {
                allTidy
            }
            Divider()
            HStack {
                Button("Open Domovy") { open(filter: nil) }
                    .keyboardShortcut("o")
                    .buttonStyle(.borderedProminent)
                Text("⌘O")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
        }
        .padding(16)
        .frame(width: 360)
        .task { await processes.refreshIfStale() }
    }

    private var header: some View {
        HStack {
            Image("MenuBarGlyph")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Domovy").fontWeight(.semibold)
            Spacer()
            if let lastScan = library.lastScan {
                Text("Scanned \(Text(lastScan, format: .relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if library.isLoading {
                Text("Scanning…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            BreakdownBar(segments: library.footprintByAgent.map { ($0.agent.displayName, $0.bytes) }, height: 8)
            ForEach(Array(library.footprintByAgent.enumerated()), id: \.offset) { index, item in
                HStack(spacing: 8) {
                    Circle()
                        .fill(BreakdownBar.color(at: index))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(item.agent.displayName)
                    Spacer()
                    SizeText(bytes: item.bytes)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var attention: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Needs attention")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(library.expiringByAgent, id: \.rule.agent) { group in
                let n = group.sessions.count
                let when = library.expiringWithinDays(group.sessions).map { $0 == 0 ? "at the next sweep" : "in \($0) \($0 == 1 ? "day" : "days")" }
                AttentionRow(
                    symbol: "clock",
                    title: "\(n) \(group.rule.agent.displayName) \(n == 1 ? "session" : "sessions") " + (when.map { "will be deleted \($0)" } ?? "near its limit"),
                    detail: group.rule.rule
                ) { open(filter: .expiring) }
            }
            let live = library.liveSessions
            if !live.isEmpty {
                AttentionRow(
                    symbol: "dot.radiowaves.left.and.right",
                    title: "\(live.count) \(live.count == 1 ? "session is" : "sessions are") live",
                    detail: live.prefix(3).map { "\($0.agent.displayName) · \($0.projectName ?? "no project")" }.joined(separator: ", ")
                ) { open(filter: .live) }
            }
            if processes.orphanCount > 0 {
                let n = processes.orphanCount
                AttentionRow(
                    symbol: "exclamationmark.circle",
                    title: "\(n) orphaned agent \(n == 1 ? "process" : "processes") (\(processes.orphanBytes.formatted(.byteCount(style: .memory))))",
                    detail: "Their agent is gone. Review them on the Processes screen."
                ) { open(section: .processes) }
            }
            if let server = processes.growingServers.first {
                AttentionRow(
                    symbol: "arrow.up.right",
                    title: "MCP server growing: \((server.footprintBytes ?? 0).formatted(.byteCount(style: .memory)))",
                    detail: "\(server.name). Freezing it stops the growth without losing anything."
                ) { open(section: .processes) }
            }
            if let bytes = library.largeVMBundleBytes {
                AttentionRow(
                    symbol: "shippingbox",
                    title: "Claude Desktop VM bundle: \(bytes.formatted(.byteCount(style: .file)))",
                    detail: "Review what removing it costs on the Disk screen."
                ) { open(section: .disk) }
            }
            if library.hasLargeModelFootprint {
                let unused = library.unusedModels(days: 60)
                AttentionRow(
                    symbol: "shippingbox.circle",
                    title: "\(library.localModelBytes.formatted(.byteCount(style: .file))) in local models",
                    detail: unused.isEmpty ? "Ollama, LM Studio and Hugging Face downloads." : "\(unused.count) older than 60 days. Review them on the Disk screen."
                ) {
                    library.requestedDiskAnchor = LocalModelsHeader.anchor
                    open(section: .disk)
                }
            }
                        if library.hasLargeSafeFootprint {
                AttentionRow(
                    symbol: "checkmark.circle",
                    title: "\(library.safeFootprintBytes.formatted(.byteCount(style: .file))) safe to remove",
                    detail: "Caches and leftovers the agents rebuild or never need."
                ) { open(section: .disk) }
            }
        }
    }

    private var allTidy: some View {
        VStack(spacing: 8) {
            Image(systemName: "smallcircle.filled.circle")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text("All tidy").font(.headline)
            Text("No sessions expire this week and nothing is leaking. The house is in order.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }

    private func open(section: SidebarItem) {
        library.requestedSection = section
        openWindow(id: "main")
        NSApp.activate()
    }

    private func open(filter: StatusFilter?) {
        library.requestedSection = filter == nil ? nil : .sessions
        library.requestedFilter = filter
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct AttentionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}
