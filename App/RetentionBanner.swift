import AppKit
import DomovyCore
import SwiftUI

/// "Claude Code deletes sessions older than 30 days. 12 sessions go in the next 4 days."
/// One per agent whose own sweep is about to take sessions.
///
/// No `.fixedSize(horizontal: false, vertical: true)` on these texts: on macOS 27 it makes
/// SwiftUI stop drawing the sidebar and the sessions Table below it. Text wraps without it.
struct RetentionBanner: View {
    let rule: RetentionRule
    let sessions: [Session]
    /// `nil` when the rule is not a date (a conversation cap).
    let withinDays: Int?
    /// Expiring sessions not archived yet, when Domovy can archive this agent's sessions.
    let archivableCount: Int
    let onArchiveAll: () -> Void
    let onReview: () -> Void
    let onDismiss: () -> Void

    private var headline: String {
        // A grouped row (Gemini CLI's empty a2a chats) counts every chat it stands for.
        let count = sessions.reduce(0) { $0 + $1.memberCount }
        let noun = rule.agent == .antigravity ? "conversation" : rule.agent == .gemini ? "chat" : "session"
        let subject = "\(count) \(noun)\(count == 1 ? "" : "s")"
        guard let withinDays else {
            return "\(rule.rule) \(subject) \(count == 1 ? "is" : "are") close to the limit or past it."
        }
        let when = withinDays == 0 ? "at the next sweep" : "in the next \(withinDays) \(withinDays == 1 ? "day" : "days")"
        return "\(rule.rule) \(subject) \(count == 1 ? "goes" : "go") \(when)."
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
                Text(rule.advice)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    if rule.canArchive, archivableCount > 0 {
                        Button("Archive all \(archivableCount)", action: onArchiveAll)
                            .buttonStyle(.borderedProminent)
                            .help("Compress the expiring sessions on disk. \(rule.agent.displayName) can still resume them.")
                    }
                    Button("Review", action: onReview)
                        .help("Show only the expiring sessions")
                    if let settingsFile = rule.settingsFile {
                        Button("Change setting…") {
                            NSWorkspace.shared.activateFileViewerSelecting([settingsFile])
                        }
                        .buttonStyle(.link)
                        .help("Reveal \(settingsFile.lastPathComponent) in the Finder")
                    }
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
