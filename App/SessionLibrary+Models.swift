import DomovyCore
import Foundation

/// Local models on the Disk screen: the "unused for N days" selection and removal, run like
/// every other plan. `ollama rm` and `hf cache rm` run after Domovy keeps a copy; both those and
/// moved files can be undone.
extension SessionLibrary {
    /// Below this, local models are not worth a line in the menu bar.
    static let modelWarningBytes: Int64 = 5_000_000_000

    /// Ollama, LM Studio and Hugging Face footprints, largest first.
    var modelFootprints: [Footprint] {
        footprints.filter { $0.agent.isModelStore }.sorted { $0.totalBytes > $1.totalBytes }
    }

    var localModels: [LocalModel] { modelFootprints.flatMap(\.models) }
    var localModelBytes: Int64 { modelFootprints.reduce(0) { $0 + $1.totalBytes } }
    var hasLargeModelFootprint: Bool { localModelBytes > Self.modelWarningBytes }

    func unusedModels(days: Int) -> [LocalModel] {
        localModels.filter { $0.isUnused(days: days) }
    }

    func modelRemovalPlan(_ models: [LocalModel], destination: Destination) async throws -> ModelRemovalPlan {
        let planner = cleanupPlanner
        return try await Task.detached { try await planner.modelRemovalPlan(models, destination: destination) }.value
    }

    func runModelRemoval(_ removal: ModelRemovalPlan, purgeNow: Bool = false) async throws {
        let planner = cleanupPlanner
        let executor = self.executor
        let entries = try await Task.detached { try await planner.execute(removal, with: executor) }.value
        let names = removal.models.count == 1 ? removal.models[0].name : "\(removal.models.count) models"
        let size = removal.totalBytes.formatted(.byteCount(style: .file))
        let freed = purgeNow ? await purgeKeptCopies(entries) : nil
        let undoable = freed == nil ? entries.filter(\.isUndoable) : []
        let message: String
        if let freed {
            message = "Removed \(names) (\(size)). \(freed)"
        } else if undoable.isEmpty {
            message = "Removed \(names) (\(size)). It's gone for good; download it again to use it."
        } else if removal.isPermanent {
            message = "Removed \(names) (\(size)). Domovy keeps a copy in its quarantine until you purge it."
        } else {
            message = "Moved \(names) (\(size)) to \((removal.plans.first?.destination ?? .trash).displayName)."
        }
        let action = UndoAction(name: "Remove Models", entries: undoable)
        if !undoable.isEmpty { register(action) }
        toast = Toast(message: message + Self.leftoverText(entries), undo: undoable.isEmpty ? nil : action)
        await reload()
    }
}
