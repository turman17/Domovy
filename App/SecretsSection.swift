import DomovyCore
import SwiftUI

/// The inspector's list of possible secrets in one session. Masked previews only.
struct SecretsSection: View {
    let session: Session
    let findings: [SecretFinding]
    let onRedact: () -> Void

    private var redactable: Int { findings.filter(\.isRedactable).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label("\(findings.count) possible \(findings.count == 1 ? "secret" : "secrets")", systemImage: "key.fill")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                Spacer()
                Button("Redact\u{2026}", action: onRedact)
                    .controlSize(.small)
                    .disabled(redactable == 0 || session.status == .live)
                    .help(redactHelp)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(findings) { finding in
                        row(finding)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
    }

    private var redactHelp: String {
        if session.status == .live { return "This session is live, so it cannot be redacted." }
        if redactable == 0 { return "None of these can be redacted safely. Delete the session to remove them." }
        return "Replace \(redactable == 1 ? "it" : "them") with [REDACTED:<rule>]. Shows the plan first. You can undo this."
    }

    private func row(_ finding: SecretFinding) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(finding.preview)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
            Text("\(finding.ruleName) \u{00B7} line \(finding.line) \u{00B7} \(finding.file.lastPathComponent)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(finding.file.path)
            if case .notRedactable(let reason) = finding.redaction {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
