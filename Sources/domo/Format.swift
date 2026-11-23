import DomovyCore
import Foundation

/// Output helpers for the CLI. Sizes are human readable, dates relative.
enum Format {
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: count)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func status(_ session: Session) -> String {
        switch session.status {
        case .live: return "live"
        case .idle: return "idle"
        case .archived: return "archived"
        case .expiring:
            let archived = session.isArchived ? ", archived" : ""
            guard let expiresAt = session.expiresAt else { return "expiring" + archived }
            let days = Int(ceil(expiresAt.timeIntervalSinceNow / 86_400))
            return (days <= 0 ? "expiring (next sweep)" : "expiring in \(days)d") + archived
        }
    }

    /// Left-aligned columns, right-aligned when `rightAligned` says so. Last column is not padded.
    static func table(_ rows: [[String]], header: [String], rightAligned: Set<Int> = []) -> String {
        let all = [header] + rows
        var widths = Array(repeating: 0, count: header.count)
        for row in all {
            for (i, cell) in row.enumerated() where i < widths.count {
                widths[i] = max(widths[i], cell.count)
            }
        }
        return all.map { row in
            row.enumerated().map { i, cell in
                if i == row.count - 1 { return cell }
                let pad = String(repeating: " ", count: max(0, widths[i] - cell.count))
                return rightAligned.contains(i) ? pad + cell : cell + pad
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }

    static func plan(_ plan: Plan) -> String {
        var lines: [String] = []
        lines.append("Plan for session \(plan.sessionID) (\(plan.agent.displayName))")
        lines.append("")
        for command in plan.commands {
            let environment = command.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            lines.append("  run    \(command.commandLine)\(environment.isEmpty ? "" : "   (\(environment))")")
            lines.append("         \(command.note)")
            if !command.copiesBeforeRun.isEmpty {
                lines.append("         keeps a copy of \(command.copiesBeforeRun.count) file(s) first, for undo")
            }
        }
        for move in plan.moves {
            let marker = move.kind == .folder ? "folder" : "file"
            lines.append("  \(bytes(move.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(marker.padding(toLength: 6, withPad: " ", startingAt: 0)) \(move.source.path)")
            lines.append("  \(String(repeating: " ", count: 10)) \(String(repeating: " ", count: 6)) \(move.note)")
        }
        for item in plan.compressions {
            let sizes = "\(bytes(item.sizeBytes)) \u{2192} ~\(bytes(item.estimatedBytes))"
            lines.append("  \(sizes.padding(toLength: 22, withPad: " ", startingAt: 0)) \(item.file.path)")
            lines.append("  \(String(repeating: " ", count: 22)) \(item.note)")
        }
        for item in plan.redactions {
            lines.append("  redact \(item.file.path)")
            for edit in item.lines {
                for replacement in edit.replacements {
                    lines.append("         line \(edit.line)  \(SecretRule.displayName(for: replacement.ruleID))  \(replacement.preview) \u{2192} [REDACTED:\(replacement.ruleID)]")
                }
            }
        }
        for item in plan.skippedSecrets {
            lines.append("  skip   \(item.file.lastPathComponent) line \(item.line)  \(item.preview): \(item.reason)")
        }
        for edit in plan.indexEdits {
            lines.append("  \(bytes(edit.removedBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) index  \(edit.file.path)")
            lines.append("  \(String(repeating: " ", count: 10)) \(String(repeating: " ", count: 6)) \(edit.note)")
        }
        lines.append("")
        lines.append("Live check: \(plan.liveCheck.isLive ? "LIVE" : "not live") (checked \(plan.liveCheck.checkedSignals.joined(separator: ", ")); open handles: \(plan.liveCheck.openHandles.rawValue))")
        if plan.action == .archive {
            lines.append("Total: \(bytes(plan.totalBytes)) \u{2192} ~\(bytes(plan.estimatedBytesAfter)) on disk")
        } else if plan.action != .redact {
            lines.append("Total: \(bytes(plan.totalBytes))")
        }
        lines.append(plan.summary)
        for remark in plan.remarks where remark != plan.summary {
            lines.append("Note: \(remark)")
        }
        return lines.joined(separator: "\n")
    }

    /// Masked findings, one per line, then the files that were skipped and the summary.
    static func findings(_ report: SecretScanReport, home: URL) -> String {
        let rows = report.findings.map { finding in
            [
                String(finding.sessionID.prefix(8)),
                finding.agent.displayName,
                displayPath(finding.file, home: home) + ":\(finding.line)",
                finding.ruleName,
                finding.preview,
                finding.isRedactable ? "yes" : "no",
            ]
        }
        var lines: [String] = []
        if !rows.isEmpty {
            lines.append(table(rows, header: ["SESSION", "AGENT", "FILE", "RULE", "PREVIEW", "REDACTABLE"]))
            lines.append("")
        }
        for item in report.skipped {
            lines.append("Skipped \(displayPath(item.file, home: home)): \(item.reason)")
        }
        lines.append(report.summary)
        if !report.findings.isEmpty {
            lines.append("Redact a session with `domo redact <id>`, or delete it with `domo rm <id> --to quarantine`.")
        }
        return lines.joined(separator: "\n")
    }

    private static func displayPath(_ url: URL, home: URL) -> String {
        let base = home.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? "~/" + path.dropFirst(base.count) : path
    }
}
