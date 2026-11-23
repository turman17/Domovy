import AppKit
import DomovyCore
import SwiftUI

/// "Claude Code deletes sessions older than 30 days. 12 sessions go in the next 4 days."
///
/// No `.fixedSize(horizontal: false, vertical: true)` on these texts: on macOS 27 it makes
/// SwiftUI stop drawing the sidebar and the sessions Table below it. Text wraps without it.
struct RetentionBanner: View {
    let sessions: [Session]
    let retentionDays: Int
    let withinDays: Int
    let settingsURL: URL
    /// Expiring sessions not archived yet.
    let archivableCount: Int
    let onArchiveAll: () -> Void
    let onReview: () -> Void
    let onDismiss: () -> Void

    private var headline: String {
        let count = sessions.count
        let when = withinDays == 0 ? "at the next sweep" : "in the next \(withinDays) \(withinDays == 1 ? "day" : "days")"
        return "Claude Code deletes sessions older than \(retentionDays) days. \(count) \(count == 1 ? "session goes" : "sessions go") \(when)."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "clock")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(headline)
                    .fontWeight(.semibold)
                Text("Archiving compresses them to free space but keeps their dates, so the sweep still applies. To keep them longer, raise cleanupPeriodDays in Claude Code settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if archivableCount > 0 {
                        Button("Archive all \(archivableCount)", action: onArchiveAll)
                            .buttonStyle(.borderedProminent)
                            .help("Compress the expiring sessions on disk. Claude Code can still resume them.")
                    }
                    Button("Review", action: onReview)
                        .help("Show only the expiring sessions")
                    Button("Change setting…") {
                        NSWorkspace.shared.activateFileViewerSelecting([settingsURL])
                    }
                    .buttonStyle(.link)
                    .help("Reveal settings.json in the Finder")
                }
                .padding(.top, 4)
            }
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 12)
        .padding(.bottom, 4)
    }
}
