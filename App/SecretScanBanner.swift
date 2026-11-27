import SwiftUI

/// "Scanning 3 of 9 sessions…" while the scan runs, then "Found 7 possible secrets in 3 sessions."
/// Accent, never red: a finding is something to tidy, not an alarm.
///
/// No `.fixedSize(horizontal: false, vertical: true)` here, for the same reason as
/// RetentionBanner: it stops SwiftUI drawing the Table below on macOS 27.
struct SecretScanBanner: View {
    let state: SecretScanState
    let showsFlaggedOnly: Bool
    let onToggleFlagged: () -> Void
    let onPurge: () -> Void
    let onCancel: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            switch state {
            case .idle:
                EmptyView()
            case .scanning(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                    .frame(width: 120)
                    .accessibilityLabel("Scan progress")
                Text("Scanning for secrets: \(done) of \(total) \(total == 1 ? "session" : "sessions")\u{2026}")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel", action: onCancel)
            case .finished(let summary, let findings):
                Image(systemName: findings > 0 ? "key.fill" : "checkmark.circle")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(summary)
                        .fontWeight(.semibold)
                    Text(findings > 0
                         ? "Previews are masked. Redact a session from the inspector, or delete it to the Domovy quarantine."
                         : "Nothing that looks like a key, token or password.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if findings > 0 {
                    Button(showsFlaggedOnly ? "Show all" : "Show flagged", action: onToggleFlagged)
                }
                Button("Purge Originals\u{2026}", action: onPurge)
                    .help("Permanently delete quarantined originals that still hold secrets")
                Button("Dismiss", systemImage: "xmark", action: onDismiss)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding([.horizontal, .top], 12)
        .padding(.bottom, 4)
    }
}
