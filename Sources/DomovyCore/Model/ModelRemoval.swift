import Foundation

/// Removing one or more local models: one `Plan` per tool, executed as one batch. A plan
/// either runs the tool's own command (`ollama rm`, `hf cache rm`), which deletes for good,
/// or moves the files to the Trash or the quarantine, which undo puts back.
public struct ModelRemovalPlan: Identifiable, Hashable, Sendable {
    public let id = UUID()
    public let models: [LocalModel]
    public let plans: [Plan]
    /// Files that stay because another model uses them, or that are new, with the reason.
    public let excluded: [CleanupExclusion]

    public init(models: [LocalModel], plans: [Plan], excluded: [CleanupExclusion]) {
        self.models = models
        self.plans = plans
        self.excluded = excluded
    }

    public var isBlocked: Bool { plans.contains { $0.liveCheck.isLive } }
    public var canExecute: Bool { !isBlocked && !plans.isEmpty && !plans.contains(where: \.isEmpty) }
    public var totalBytes: Int64 { plans.reduce(0) { $0 + $1.totalBytes } }
    public var reasons: [String] { plans.flatMap(\.liveCheck.reasons) }

    /// Every plan's checks as one result, for a single row in the sheet.
    public var liveCheck: LiveCheckResult {
        let statuses = plans.map(\.liveCheck.openHandles)
        let status: LiveCheckResult.OpenHandleStatus = statuses.contains(.open) ? .open : statuses.contains(.unavailable) ? .unavailable : .clear
        var signals: [String] = []
        for signal in plans.flatMap(\.liveCheck.checkedSignals) where !signals.contains(signal) { signals.append(signal) }
        return LiveCheckResult(isLive: isBlocked, reasons: reasons, checkedSignals: signals, openHandles: status)
    }

    /// Some of it is deleted by the tool itself and cannot be undone.
    public var isPermanent: Bool { plans.contains { $0.isPermanent } }
    /// All of it can be put back.
    public var isUndoable: Bool { !plans.contains { $0.isPermanent } }

    /// "Remove qwen3:14b?" or "Remove 3 models?"
    public var title: String {
        models.count == 1 ? "Remove \(models[0].name)?" : "Remove \(models.count) models?"
    }

    /// Exactly what happens, per tool, in the Domovy voice.
    public var summary: String {
        if isBlocked { return "Nothing will change yet. " + reasons.joined(separator: " ") }
        return plans.map(\.modelSummary).joined(separator: " ")
    }
}

extension Plan {
    /// A command deletes for good and Domovy keeps no copy.
    public var isPermanent: Bool { commands.contains(where: \.isPermanent) }

    /// One plan of a model removal or model cleanup, said plainly.
    var modelSummary: String {
        let size = CleanupPlan.bytes(totalBytes)
        if isPermanent {
            let n = commands.count
            return "\(agent.displayName) deletes \(n == 1 ? "it" : "them") (\(size)); Undo can't bring \(n == 1 ? "it" : "them") back."
        }
        let n = moves.count
        return "Moves \(n) \(n == 1 ? "item" : "items") (\(size)) to \((destination ?? .trash).displayName). You can undo this."
    }
}
