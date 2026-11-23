import DomovyCore
import SwiftUI

/// Menu bar popover: total footprint, breakdown by agent, what needs attention, Open Domovy.
struct MenuBarView: View {
    @Environment(SessionLibrary.self) private var library
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
            if library.needsAttention || !library.liveSessions.isEmpty {
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
            let expiring = library.expiringSessions
            if !expiring.isEmpty {
                let days = library.expiringWithinDays
                AttentionRow(
                    symbol: "clock",
                    title: "\(expiring.count) Claude Code \(expiring.count == 1 ? "session" : "sessions") will be deleted \(days == 0 ? "at the next sweep" : "in \(days) \(days == 1 ? "day" : "days")")",
                    detail: "Review them, or raise cleanupPeriodDays to keep them."
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

    private func open(filter: StatusFilter?) {
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
