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

    /// Memory sizes count in binary units, as Activity Monitor does.
    static func memory(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }

    static func state(_ node: ProcessNode) -> String {
        var parts: [String] = []
        if node.isFrozen { parts.append("frozen") }
        if node.isOrphan { parts.append("orphan") }
        if node.isGrowing { parts.append("growing" + (node.growthBytes.map { " +\(memory($0))" } ?? "")) }
        if node.refusal != nil, parts.isEmpty { parts.append("protected") }
        return parts.isEmpty ? "running" : parts.joined(separator: ", ")
    }

    static func processPlan(_ plan: ProcessActionPlan) -> String {
        var lines = ["\(plan.action.title) \(plan.rootName)", ""]
        for target in plan.targets {
            lines.append("  \(String(target.pid).padding(toLength: 8, withPad: " ", startingAt: 0)) \((target.footprintBytes.map(memory) ?? "–").padding(toLength: 10, withPad: " ", startingAt: 0)) \(target.name)")
        }
        lines.append("")
        lines.append(plan.summary)
        return lines.joined(separator: "\n")
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

    /// The first 8 characters; OpenCode's `ses_` ids share their first characters, so 14.
    static func shortID(_ id: String) -> String {
        String(id.prefix(id.hasPrefix("ses_") ? 14 : 8))
    }

    static func plan(_ plan: Plan) -> String {
        var lines: [String] = []
        lines.append("Plan for session \(plan.sessionID) (\(plan.agent.displayName))")
        lines.append("")
        for command in plan.commands {
            let environment = command.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
            lines.append("  run    \(command.commandLine)\(environment.isEmpty ? "" : "   (\(environment))")")
            if let directory = command.workingDirectory { lines.append("         in \(directory.path)") }
            lines.append("         \(command.note)")
            if !command.copiesBeforeRun.isEmpty {
                lines.append("         keeps a copy of \(command.copiesBeforeRun.count) file(s) first, for undo")
            }
            if !command.snapshotsBeforeRun.isEmpty {
                let names = command.snapshotsBeforeRun.map(\.lastPathComponent).joined(separator: ", ")
                lines.append("         keeps a copy of \(names) first; undo works only while nothing else changes them")
            }
        }
        for move in plan.moves {
            let marker = move.kind == .folder ? "folder" : "file"
            lines.append("  \(bytes(move.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(marker.padding(toLength: 6, withPad: " ", startingAt: 0)) \(move.source.path)")
            lines.append("  \(String(repeating: " ", count: 10)) \(String(repeating: " ", count: 6)) \(move.note)")
        }
        for item in plan.relocations {
            lines.append("  \(bytes(item.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) move   \(item.source.path)")
            lines.append("  \(String(repeating: " ", count: 10))   to   \(item.target.path)")
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
        for edit in plan.databaseEdits {
            lines.append("  \(bytes(edit.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) rows   \(edit.database.path)")
            lines.append("  \(String(repeating: " ", count: 10)) \(String(repeating: " ", count: 6)) keeps a copy of \(edit.files.map(\.lastPathComponent).joined(separator: ", ")) first, then checks PRAGMA integrity_check")
            for rows in edit.rows {
                let key = rows.isPrefix ? "\(rows.key)*" : rows.key
                lines.append("  \(String(repeating: " ", count: 10)) \(String(repeating: " ", count: 6)) delete \(rows.count) \(rows.count == 1 ? "row " : "rows") \(rows.table) \(key)  (\(rows.note))")
            }
            for removal in edit.listRemovals {
                lines.append("  \(String(repeating: " ", count: 10)) \(String(repeating: " ", count: 6)) edit   \(removal.table) \(removal.key)  (\(removal.note))")
            }
        }
        for removal in plan.jsonRemovals {
            lines.append("  \(bytes(removal.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) entry  \(removal.file.path)")
            lines.append("  \(String(repeating: " ", count: 10)) \(String(repeating: " ", count: 6)) \(removal.note); keeps a copy first")
        }
        for removal in plan.registryRemovals {
            lines.append("  \(bytes(removal.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) entry  \(removal.file.path)")
            lines.append("  \(String(repeating: " ", count: 10)) \(String(repeating: " ", count: 6)) \(removal.note)")
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
        if let acknowledgement = plan.acknowledgement {
            lines.append("Needs your OK: \(acknowledgement)")
        }
        return lines.joined(separator: "\n")
    }

    /// A cleanup plan, then what it leaves alone and why.
    static func cleanup(_ cleanup: CleanupPlan, home: URL) -> String {
        var lines = [plan(cleanup.plan)
            .replacingOccurrences(of: "Plan for session \(cleanup.plan.sessionID)", with: "Cleanup \(cleanup.cleanup.rawValue)")
            .replacingOccurrences(of: "\n" + cleanup.plan.summary, with: "\n" + cleanup.summary)]
        if !cleanup.excluded.isEmpty {
            lines.append("")
            lines.append("Kept:")
            for item in cleanup.excluded {
                lines.append("  \(bytes(item.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(displayPath(item.url, home: home))")
                lines.append("  \(String(repeating: " ", count: 10)) \(item.reason)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Orphans and duplicates, one per line, with what stays for each duplicate.
    static func orphans(_ report: OrphanReport, home: URL) -> String {
        var lines: [String] = []
        let kinds: [OrphanItem.Kind: String] = [
            .companion: "companion", .desktopEntry: "desktop", .duplicateCopy: "copy",
            .duplicateSession: "session", .duplicateDesktopEntry: "desktop",
        ]
        let orphanRows = report.orphans.map { [kinds[$0.kind] ?? "", String($0.sessionID.prefix(8)), bytes($0.sizeBytes), displayPath($0.url, home: home)] }
        lines.append("Orphans: \(report.orphanSummary)")
        if !orphanRows.isEmpty { lines.append(table(orphanRows, header: ["KIND", "SESSION", "SIZE", "PATH"], rightAligned: [2])) }
        lines.append("")
        lines.append("Duplicates: \(report.duplicateSummary)")
        for group in report.duplicates {
            lines.append("  \(group.sessionID.prefix(8)): keeps \(group.kept.map { displayPath($0, home: home) }.joined(separator: ", "))")
            for item in group.extra {
                lines.append("    \((kinds[item.kind] ?? "").padding(toLength: 8, withPad: " ", startingAt: 0)) \(bytes(item.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(displayPath(item.url, home: home))")
            }
        }
        if case .readOnly(let reason) = report.desktopStatus { lines.append("\nNote: \(reason)") }
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

extension Format {
    /// "1.2M".
    static func tokens(_ count: Int64) -> String {
        TokenCounts.compact(count)
    }

    /// "~$1.24", with "+" when some models have no price.
    static func cost(_ estimate: CostEstimate) -> String {
        let text = estimate.usd > 0 && estimate.usd < 0.01 ? "<$0.01" : "~$" + String(format: "%.2f", estimate.usd)
        return estimate.isPartial ? text + "+" : text
    }
}
