import DomovyCore
import SwiftUI

/// "Left behind": orphans and duplicates, each with a count, a size and its cleanup button.
/// The button uses the accent; red is kept for the final confirmation in the sheet.
struct OrphansSection: View {
    let report: OrphanReport
    let onCleanUp: (OrphanScope) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Left behind")
                    .foregroundStyle(.secondary)
                Spacer()
                SizeText(bytes: report.orphanBytes + report.duplicateBytes)
                    .font(.system(.callout, design: .monospaced))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                if !report.orphans.isEmpty {
                    row(
                        title: "Orphans",
                        detail: report.orphanSummary,
                        bytes: report.orphanBytes,
                        button: "Clean Up Orphans\u{2026}",
                        scope: .orphans
                    )
                }
                if !report.orphans.isEmpty && !report.duplicates.isEmpty { Divider() }
                if !report.duplicates.isEmpty {
                    row(
                        title: "Duplicates",
                        detail: report.duplicateSummary,
                        bytes: report.duplicateBytes,
                        button: "Remove Duplicates\u{2026}",
                        scope: .duplicates
                    )
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            if case .readOnly(let reason) = report.desktopStatus {
                Label(reason, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(title: String, detail: String, bytes: Int64, button: String, scope: OrphanScope) -> some View {
        HStack(spacing: 16) {
            DispositionBadge(disposition: .safe)
                .frame(width: 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.semibold)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(bytes.formatted(.byteCount(style: .file)))
                .font(.system(.callout, design: .monospaced))
                .help("\(bytes.formatted()) bytes")
            Button(button) { onCleanUp(scope) }
                .buttonStyle(.borderedProminent)
                .help("Shows every item first. Moves them to the Trash; you can undo this. Claude Desktop entries change only while Claude Desktop is quit.")
                .frame(minWidth: 116, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}
