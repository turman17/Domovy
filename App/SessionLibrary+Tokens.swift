import DomovyCore
import Foundation
import SwiftUI

/// Token counts for the Tokens column, Get Info and project totals. Read after each scan in
/// the background: cached answers first, then the transcripts that changed.
extension SessionLibrary {
    func refreshTokens() {
        tokenTask?.cancel()
        let sessions = self.sessions, adapters = self.adapters, store = tokenStore
        tokenTask = Task { [weak self] in
            let cached = await Task.detached(priority: .utility) {
                await store.usage(for: sessions, adapters: adapters, cachedOnly: true)
            }.value
            guard !Task.isCancelled, let self else { return }
            publishTokens(cached)
            let fresh = await Task.detached(priority: .utility) {
                let found = await store.usage(for: sessions, adapters: adapters)
                store.prune(keeping: sessions)
                return found
            }.value
            guard !Task.isCancelled else { return }
            publishTokens(fresh)
        }
    }

    private func publishTokens(_ usage: [Session.ID: TokenUsageResult]) {
        guard usage != tokenUsage else { return }
        tokenUsage = usage
        tokenRevision += 1
    }

    /// Whether the session's agent records tokens (else the column shows "—").
    func recordsTokens(_ session: Session) -> Bool {
        TokenUsageStore.isSupported(session, adapters: adapters)
    }

    /// Agents whose transcripts record tokens.
    var tokenAgents: Set<AgentKind> {
        Set(adapters.filter { $0 is any TokenUsageReporting }.map(\.kind))
    }

    /// Tokens of `sessions` that record them, and how many do.
    func tokenTotals(of sessions: [Session]) -> (usage: TokenUsage, counted: Int) {
        ProjectGroup(path: nil, sessions: sessions).tokens(in: tokenUsage)
    }
}

extension TokenUsage {
    /// "Input 1,200 · Output 300 · Cache read 4,000 · Cache write 0", then models and cost.
    var breakdown: String {
        let t = totals
        var lines = ["\(t.total.formatted()) tokens",
                     "Input \(t.input.formatted()) \u{00B7} Output \(t.output.formatted())",
                     "Cache read \(t.cacheRead.formatted()) \u{00B7} Cache write \(t.cacheWrite.formatted())"]
        if !models.isEmpty { lines.append("Models: " + models.joined(separator: ", ")) }
        if let cost { lines.append("\(cost.text). \(cost.explanation)") }
        return lines.joined(separator: "\n")
    }
}

/// "Export Transcript…" in the File menu acts on the sessions window's selection.
struct ExportAction {
    let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) {
        self.perform = perform
    }
}

/// The Session menu's items for the sessions window's selection; nil disables an item.
struct SessionCommands {
    var quickLook: (@MainActor () -> Void)?
    var getInfo: (@MainActor () -> Void)?
    var archive: (@MainActor () -> Void)?
    var delete: (@MainActor () -> Void)?
}

extension FocusedValues {
    @Entry var exportTranscripts: ExportAction?
    @Entry var sessionCommands: SessionCommands?
}
