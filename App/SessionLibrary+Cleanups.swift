import DomovyCore
import Foundation

/// The Disk screen's guided cleanups, run like every other plan: shown first, undoable after.
extension SessionLibrary {
    func cleanupPlan(_ id: CleanupID, destination: Destination) async throws -> CleanupPlan {
        let planner = cleanupPlanner
        return try await Task.detached { try await planner.plan(id, destination: destination) }.value
    }

    func runCleanup(_ cleanup: CleanupPlan) async throws {
        let planner = cleanupPlanner
        let executor = self.executor
        let entry = try await Task.detached { try await planner.execute(cleanup, with: executor) }.value
        let plan = cleanup.plan
        let message: String
        if cleanup.cleanup.compresses {
            let done = Set(entry.compressed.map(\.file))
            let items = plan.compressions.filter { done.contains($0.file) }
            let before = items.reduce(Int64(0)) { $0 + $1.sizeBytes }.formatted(.byteCount(style: .file))
            let after = items.reduce(Int64(0)) { $0 + $1.estimatedBytes }.formatted(.byteCount(style: .file))
            message = items.isEmpty
                ? "Nothing needed compressing."
                : "Compressed \(items.count) \(items.count == 1 ? "rollout" : "rollouts") (\(before) \u{2192} ~\(after))."
        } else if !plan.commands.isEmpty {
            let lines = plan.commands.map { "`\($0.commandLine)`" }.joined(separator: ", ")
            message = "Ran \(lines) (\(plan.totalBytes.formatted(.byteCount(style: .file))))." + Self.leftoverText([entry])
        } else {
            let n = entry.moved.count
            message = "Moved \(n) \(n == 1 ? "item" : "items") (\(plan.totalBytes.formatted(.byteCount(style: .file)))) to \((plan.destination ?? .trash).displayName)."
        }
        let undoable = entry.isUndoable && (!entry.moved.isEmpty || !entry.compressed.isEmpty)
        let action = UndoAction(name: cleanup.cleanup.compresses ? "Compress" : "Move to Trash", entries: [entry])
        if undoable { register(action) }
        toast = Toast(message: message, undo: undoable ? action : nil)
        await reload()
    }

    /// The footprint row of a cleanup, for the menu bar warnings.
    func category(_ id: CleanupID) -> Footprint.Category? {
        footprints.lazy.flatMap(\.categories).first { $0.cleanupID == id }
    }
}
