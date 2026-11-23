import DomovyCore
import Foundation

/// Where the secret scan is, for the banner.
enum SecretScanState: Equatable {
    case idle
    case scanning(done: Int, total: Int)
    case finished(summary: String, findings: Int)
}

/// Secret scan, redaction and purge. Findings live in memory only and hold masked previews.
extension SessionLibrary {
    var flaggedSessionCount: Int { secretFindings.values.filter { !$0.isEmpty }.count }

    func findings(for session: Session) -> [SecretFinding] {
        secretFindings[session.id] ?? []
    }

    /// Starts a scan of `sessions` off the main actor; a running scan is cancelled first.
    func scanSecrets(_ sessions: [Session]) {
        secretScanTask?.cancel()
        let adapters = self.adapters
        secretScan = .scanning(done: 0, total: sessions.count)
        let update: @Sendable (SecretScanProgress) -> Void = { [weak self] progress in
            guard let self else { return }
            Task { @MainActor in
                guard case .scanning = self.secretScan else { return }
                self.secretScan = .scanning(done: progress.sessionsDone, total: progress.sessionsTotal)
            }
        }
        secretScanTask = Task { [weak self] in
            let report: SecretScanReport
            do {
                let scan = Task.detached {
                    try await SecretScanner().scan(await SecretScanner.targets(for: sessions, adapters: adapters), progress: update)
                }
                // Cancelling this task cancels the detached scan too.
                report = try await withTaskCancellationHandler { try await scan.value } onCancel: { scan.cancel() }
            } catch {
                guard let self else { return }
                if !(error is CancellationError) { self.actionError = error.localizedDescription }
                self.secretScan = .idle
                return
            }
            guard let self, !Task.isCancelled else { return }
            for session in sessions { self.secretFindings[session.id] = nil }
            for (id, found) in report.findingsBySession { self.secretFindings[id] = found }
            self.secretScan = .finished(summary: report.summary, findings: report.findings.count)
        }
    }

    func cancelSecretScan() {
        secretScanTask?.cancel()
        secretScanTask = nil
        secretScan = .idle
    }

    func dismissSecretScan() {
        if case .finished = secretScan { secretScan = .idle }
    }

    /// Rescans a few sessions quietly, after a redaction or its undo.
    func rescanSecrets(_ ids: Set<Session.ID>) async {
        let targets = sessions.filter { ids.contains($0.id) }
        let adapters = self.adapters
        let report = try? await Task.detached {
            try await SecretScanner().scan(await SecretScanner.targets(for: targets, adapters: adapters))
        }.value
        guard let report else { return }
        for id in ids { secretFindings[id] = nil }
        for (id, found) in report.findingsBySession { secretFindings[id] = found }
    }

    // MARK: Redact

    func redactionPlan(for session: Session) async throws -> Plan {
        try await RedactionPlanner.plan(for: session, findings: findings(for: session), adapter: adapter(for: session.agent))
    }

    func redact(_ plan: Plan, for session: Session) async throws {
        let entries = try await run([plan])
        let n = entries.flatMap(\.redacted).reduce(0) { $0 + $1.replacements }
        let action = UndoAction(name: "Redact", entries: entries)
        register(action)
        toast = Toast(
            message: "Redacted \(n) \(n == 1 ? "secret" : "secrets") in \u{201C}\(session.displayTitle)\u{201D}. The original is in Domovy's quarantine.",
            undo: action
        )
        await reload()
        await rescanSecrets([session.id])
    }

    // MARK: Purge

    func purgePlan() async throws -> PurgePlan {
        let executor = self.executor
        return try await Task.detached { try executor.purgePlan() }.value
    }

    /// The only permanent delete in Domovy. The actions it ends leave the undo stack.
    func purge(_ plan: PurgePlan) async throws {
        let executor = self.executor
        let purged = try await Task.detached { try executor.purge(plan) }.value
        let ended = Set(purged.map(\.id))
        for action in registeredUndoActions where action.entries.contains(where: { ended.contains($0.id) }) {
            undoManager?.removeAllActions(withTarget: action)
        }
        registeredUndoActions.removeAll { action in action.entries.contains { ended.contains($0.id) } }
        let size = plan.totalBytes.formatted(.byteCount(style: .file))
        toast = Toast(message: "Permanently deleted \(plan.items.count) \(plan.items.count == 1 ? "original" : "originals") (\(size)) from Domovy's quarantine.", undo: nil)
    }
}
