import AppKit
import DomovyCore
import SwiftUI

/// Disk: where every agent's bytes are, each category marked safe / consequences / keep.
/// Read-only in this version: rows reveal files in Finder or lead to the Sessions list.
struct DiskView: View {
    /// Switches the sidebar to Sessions, filtered by this agent.
    let onOpenSessions: (AgentKind) -> Void

    @Environment(SessionLibrary.self) private var library

    /// Largest agent first, matching the breakdown bar and its legend.
    private var ordered: [Footprint] {
        library.footprints.sorted { $0.totalBytes > $1.totalBytes }
    }

    private var subtitle: String {
        let total = library.totalFootprintBytes.formatted(.byteCount(style: .file))
        let safe = library.safeFootprintBytes.formatted(.byteCount(style: .file))
        return "\(total) used by AI agents · \(safe) safe to remove"
    }

    var body: some View {
        Group {
            if library.footprints.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        breakdown
                        ForEach(ordered, id: \.agent) { footprint in
                            AgentFootprintSection(footprint: footprint, onOpenSessions: onOpenSessions)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
            }
        }
        .navigationTitle("Disk")
        .navigationSubtitle(library.footprints.isEmpty ? "" : subtitle)
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
                description: Text("Domovy looked for Claude Code, Claude Desktop, Codex and Cursor and found none. The house is in order.")
            )
        }
    }
}

/// One agent: glyph, name and total, then its categories in a rounded box.
private struct AgentFootprintSection: View {
    let footprint: Footprint
    let onOpenSessions: (AgentKind) -> Void

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
                    CategoryRow(category: category, agent: footprint.agent, onOpenSessions: onOpenSessions)
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
    let onOpenSessions: (AgentKind) -> Void

    private var instructions: String? {
        if case .instructions(let text) = category.guidance { return text }
        return nil
    }

    var body: some View {
        HStack(spacing: 16) {
            DispositionBadge(disposition: category.disposition)
                .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .fontWeight(.semibold)
                Text(category.note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
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
        if category.guidance == .manageInSessions {
            Button("Open Sessions") { onOpenSessions(agent) }
                .help("Delete or archive \(agent.displayName) sessions one by one")
        } else {
            Button("Show in Finder", action: reveal)
                .help((category.url.path as NSString).abbreviatingWithTildeInPath)
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
