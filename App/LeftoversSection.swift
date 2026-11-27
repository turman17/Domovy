import AppKit
import DomovyCore
import SwiftUI

/// Disk: "Leftover checkouts and build output". One box per repository or project folder, its
/// agent worktrees first, then its build output. Worktrees with work only they hold are kept
/// and say so loudly; removing one is a separate, explicit choice.
struct LeftoversSection: View {
    static let anchor = "leftovers"

    let report: LeftoverReport
    /// Opens the plan sheet with this selection; the second set holds worktrees with work.
    let onReview: (_ selection: Set<URL>, _ includingWork: Set<URL>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Leftover checkouts and build output")
                    .foregroundStyle(.secondary)
                Spacer()
                SizeText(bytes: report.reclaimableBytes)
                    .font(.system(.callout, design: .monospaced))
                Button("Review\u{2026}") { onReview(report.defaultSelection, []) }
                    .buttonStyle(.borderedProminent)
                    .disabled(report.selectable.isEmpty)
                    .help("Shows every folder first, then moves them to the Trash or quarantine. You can undo this.")
            }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isHeader)
            Text("Worktrees agents left in your projects, and folders a build or install recreates.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(report.groups) { group in
                LeftoverGroupBox(group: group, onReview: onReview)
            }
        }
    }
}

private struct LeftoverGroupBox: View {
    let group: LeftoverGroup
    let onReview: (Set<URL>, Set<URL>) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(group.name)
                    .fontWeight(.semibold)
                Text((group.root.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                SizeText(bytes: group.reclaimableBytes)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .help("Can be freed in this project")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            ForEach(group.worktrees) { worktree in
                Divider()
                WorktreeRow(worktree: worktree, onReview: onReview)
            }
            ForEach(group.buildOutputs) { output in
                Divider()
                BuildOutputRow(output: output, onReview: onReview)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

private struct WorktreeRow: View {
    let worktree: AgentWorktree
    let onReview: (Set<URL>, Set<URL>) -> Void

    private var disposition: Footprint.Disposition { worktree.isLeftover ? .consequences : .keep }

    var body: some View {
        HStack(spacing: 16) {
            DispositionBadge(disposition: disposition)
                .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let agent = worktree.agent { AgentGlyph(agent: agent) }
                    Text("Worktree \(worktree.url.lastPathComponent)")
                        .fontWeight(.semibold)
                    if let branch = worktree.branch {
                        Text(branch)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                if worktree.hasWork {
                    // Loud on purpose: this work exists nowhere else.
                    Label(worktree.state.reason, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(2)
                    Text("Kept. Commit or stash the work first, or remove it anyway from the context menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(worktree.state.reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if let lastActive = worktree.lastActive {
                    Text("\(worktree.sessionCount) \(worktree.sessionCount == 1 ? "session" : "sessions"), last active \(lastActive.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(lastActive.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(worktree.sizeBytes.formatted(.byteCount(style: .file)))
                .font(.system(.callout, design: .monospaced))
                .help("\(worktree.sizeBytes.formatted()) bytes on disk")
            Group {
                if worktree.isLeftover {
                    Button("Remove\u{2026}") { onReview([worktree.url], []) }
                        .help("Shows exactly what moves first, then moves the folder to the Trash or quarantine; the branch stays. You can undo this.")
                } else {
                    Button("Show in Finder", action: reveal)
                        .help((worktree.url.path as NSString).abbreviatingWithTildeInPath)
                }
            }
            .frame(minWidth: 116, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show in Finder", action: reveal)
            if worktree.hasWork {
                Button("Remove Anyway\u{2026}") { onReview([], [worktree.url]) }
            }
        }
        .accessibilityElement(children: .combine)
        // The context menu's items, for VoiceOver.
        .accessibilityAction(named: "Show in Finder", reveal)
        .accessibilityAction(named: "Remove Anyway") { if worktree.hasWork { onReview([], [worktree.url]) } }
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([worktree.url])
    }
}

private struct BuildOutputRow: View {
    let output: BuildOutput
    let onReview: (Set<URL>, Set<URL>) -> Void

    private var place: String {
        let relative = relativePath(output.url, under: output.checkout)
        return output.isInMainCheckout ? relative : "\(output.checkout.lastPathComponent)/\(relative)"
    }

    var body: some View {
        HStack(spacing: 16) {
            DispositionBadge(disposition: output.isRemovable ? .safe : .keep)
                .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(place)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(output.inUse ?? "Safe: rebuildable. \(output.kind.explanation)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(output.sizeBytes.formatted(.byteCount(style: .file)))
                .font(.system(.callout, design: .monospaced))
                .help("\(output.sizeBytes.formatted()) bytes on disk")
            Group {
                if output.isRemovable {
                    Button("Remove\u{2026}") { onReview([output.url], []) }
                        .help("Shows exactly what moves first, then moves the folder to the Trash or quarantine. You can undo this.")
                } else {
                    Button("Show in Finder", action: reveal)
                }
            }
            .frame(minWidth: 116, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { Button("Show in Finder", action: reveal) }
        .accessibilityElement(children: .combine)
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([output.url])
    }
}
