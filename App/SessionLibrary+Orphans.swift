import DomovyCore
import Foundation

/// The orphan finder's cleanups, run like every other plan: shown first, undoable after.
extension SessionLibrary {
    func orphanPlan(_ scope: OrphanScope, destination: Destination) async throws -> Plan {
        let claudeCode = self.claudeCode
        return try await Task.detached { try await claudeCode.orphanPlan(scope, destination: destination) }.value
    }

    func cleanUp(_ plan: Plan, scope: OrphanScope) async throws {
        let entries = try await run([plan])
        let action = UndoAction(name: scope == .orphans ? "Clean Up Orphans" : "Remove Duplicates", entries: entries)
        register(action)
        let moved = entries.reduce(0) { $0 + $1.moved.count }
        let unlisted = entries.reduce(0) { $0 + $1.registryRestores.count }
        var parts: [String] = []
        if moved > 0 { parts.append("moved \(moved) \(moved == 1 ? "item" : "items") (\(plan.totalBytes.formatted(.byteCount(style: .file)))) to \((plan.destination ?? .trash).displayName)") }
        if unlisted > 0 { parts.append("took \(unlisted) \(unlisted == 1 ? "entry" : "entries") off Claude Desktop's list") }
        let text = parts.isEmpty ? "Nothing needed cleaning up." : parts.joined(separator: " and ") + "."
        toast = Toast(message: text.prefix(1).uppercased() + text.dropFirst(), undo: parts.isEmpty ? nil : action)
        await reload()
    }
}
