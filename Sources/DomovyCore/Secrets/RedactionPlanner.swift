import Foundation

/// Builds the redaction plan for one session from its scan findings. Every finding is either
/// planned or listed as skipped with a reason; nothing is guessed.
public enum RedactionPlanner {
    public static func plan(for session: Session, findings: [SecretFinding], adapter: any AgentAdapter) async throws -> Plan {
        guard session.agent == adapter.kind else { throw AdapterError.sessionNotFound(session.id) }
        switch await adapter.status() {
        case .notInstalled: throw AdapterError.notInstalled(adapter.kind)
        case .readOnly(let reason): throw AdapterError.readOnly(adapter.kind, reason: reason)
        case .ready: break
        }
        let own = findings.filter { $0.sessionID == session.id && $0.agent == session.agent }
        let allowed = Set(SecretScanner.files(of: try await adapter.artifacts(of: session)))

        var skipped: [SkippedSecret] = []
        var byFile: [URL: [SecretFinding]] = [:]
        for finding in own {
            let reason: String?
            switch finding.redaction {
            case .notRedactable(let why): reason = why
            case .inJSONString: reason = allowed.contains(finding.file) ? nil : "The file is no longer part of this session."
            }
            if let reason {
                skipped.append(SkippedSecret(file: finding.file, line: finding.line, ruleID: finding.ruleID, preview: finding.preview, reason: reason))
            } else {
                byFile[finding.file, default: []].append(finding)
            }
        }

        let redactions = byFile.keys.sorted { $0.path < $1.path }.compactMap { file -> FileRedaction? in
            let items = byFile[file] ?? []
            let lines = Dictionary(grouping: items, by: \.lineOffset).values.map { group in
                FileRedaction.LineEdit(
                    line: group[0].line,
                    offset: group[0].lineOffset,
                    length: group[0].lineLength,
                    replacements: group.sorted { $0.byteRange.lowerBound < $1.byteRange.lowerBound }
                        .map { FileRedaction.Replacement(ruleID: $0.ruleID, range: $0.rangeInLine, preview: $0.preview) }
                )
            }
            return FileRedaction(
                file: file,
                sizeBytes: FileSystem.size(of: file),
                modificationTime: FileSystem.modificationTime(of: file),
                wasCompressed: APFSCompression.isCompressed(file),
                lines: lines.sorted { $0.offset < $1.offset },
                note: "\(items.count) \(items.count == 1 ? "value" : "values") on \(lines.count) \(lines.count == 1 ? "line" : "lines")"
            )
        }

        var remarks: [String] = []
        if !skipped.isEmpty {
            remarks.append("\(skipped.count) \(skipped.count == 1 ? "finding stays" : "findings stay") as \(skipped.count == 1 ? "it is" : "they are"): Domovy cannot redact \(skipped.count == 1 ? "it" : "them") safely. Deleting the session removes \(skipped.count == 1 ? "it" : "them").")
        }
        if redactions.contains(where: \.wasCompressed) {
            remarks.append("Archived files are compressed again after the rewrite.")
        }
        remarks.append(contentsOf: otherCopiesRemark(for: adapter))

        let live = try await adapter.liveCheck(session)
        return Plan(
            agent: session.agent,
            sessionID: session.id,
            action: .redact,
            destination: .quarantine,
            moves: [],
            indexEdits: [],
            redactions: redactions,
            skippedSecrets: skipped,
            remarks: remarks,
            liveCheck: live
        )
    }

    /// Where the agent may keep the same text that Domovy does not change.
    private static func otherCopiesRemark(for adapter: any AgentAdapter) -> [String] {
        switch adapter.kind {
        case .claudeCode:
            return ["Your prompt history (history.jsonl) is shared by all sessions; Domovy does not scan or change it."]
        case .codex:
            let database = adapter.root.appendingPathComponent("thread_history_1.sqlite")
            guard FileSystem.exists(database) else { return [] }
            return ["Codex also keeps message text in thread_history_1.sqlite. Domovy never edits Codex's databases, so a copy may stay there."]
        default:
            return []
        }
    }
}
