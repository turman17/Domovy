import DomovyCore
import SwiftUI

/// Inspector for several selected sessions: how many, how big, which agents, what is live or
/// archived, and the two batch actions.
struct SelectionSummary: View {
    let sessions: [Session]
    let canArchive: Bool
    let canDelete: Bool
    let onArchive: () -> Void
    let onDelete: () -> Void

    private var totalBytes: Int64 { sessions.reduce(0) { $0 + $1.sizeBytes } }
    private var liveCount: Int { sessions.filter { $0.status == .live }.count }
    private var archivedCount: Int { sessions.filter(\.isArchived).count }

    /// Agents with their session count and size, largest first.
    private var byAgent: [(agent: AgentKind, count: Int, bytes: Int64)] {
        Dictionary(grouping: sessions, by: \.agent)
            .map { (agent: $0.key, count: $0.value.count, bytes: $0.value.reduce(0) { $0 + $1.sizeBytes }) }
            .sorted { $0.bytes > $1.bytes }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(sessions.count) sessions selected")
                    .font(.headline)
                Text("\(totalBytes.formatted(.byteCount(style: .file))) in all")
                    .foregroundStyle(.secondary)
                    .help("\(totalBytes.formatted()) bytes")
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(byAgent, id: \.agent) { item in
                        HStack(spacing: 8) {
                            AgentGlyph(agent: item.agent)
                            Text(item.agent.displayName)
                            Text("\(item.count)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Spacer()
                            SizeText(bytes: item.bytes)
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if liveCount > 0 || archivedCount > 0 {
                        Divider()
                    }
                    if liveCount > 0 {
                        Label(
                            "\(liveCount) \(liveCount == 1 ? "is" : "are") live and will be left alone.",
                            systemImage: "dot.radiowaves.left.and.right"
                        )
                        .foregroundStyle(.secondary)
                    }
                    if archivedCount > 0 {
                        Label("\(archivedCount) already archived.", systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Archive\u{2026}", systemImage: "archivebox", action: onArchive)
                    .disabled(!canArchive)
                Spacer()
                Button("Move to Trash\u{2026}", systemImage: "trash", action: onDelete)
                    .disabled(!canDelete)
            }
            .padding(16)
        }
    }
}
