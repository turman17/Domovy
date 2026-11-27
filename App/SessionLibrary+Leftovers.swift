import DomovyCore
import Foundation

/// Leftover agent worktrees and build output, planned and run like every other cleanup: shown
/// first, undoable after.
extension SessionLibrary {
    var leftoverScanner: LeftoverScanner {
        LeftoverScanner(home: home, codexRoot: root(for: .codex))
    }

    func leftoverReport() async -> LeftoverReport {
        let scanner = leftoverScanner
        let sessions = self.sessions
        return await Task.detached { await scanner.scan(sessions: sessions) }.value
    }

    func leftoverPlan(_ selection: Set<URL>, includingWork: Set<URL>, in report: LeftoverReport, destination: Destination) async -> LeftoverPlan {
        let scanner = leftoverScanner
        let sessions = self.sessions
        return await Task.detached {
            await scanner.plan(selection, includingWork: includingWork, in: report, sessions: sessions, destination: destination)
        }.value
    }

    func runLeftovers(_ leftover: LeftoverPlan) async throws {
        let scanner = leftoverScanner
        let executor = self.executor
        let entry = try await Task.detached { try await scanner.execute(leftover, with: executor) }.value
        let n = entry.moved.count
        let destination = (leftover.plan.destination ?? .trash).displayName
        let message = "Moved \(n) \(n == 1 ? "folder" : "folders") (\(leftover.plan.totalBytes.formatted(.byteCount(style: .file)))) to \(destination)."
        let action = UndoAction(name: "Move to Trash", entries: [entry])
        let undoable = entry.isUndoable && !entry.moved.isEmpty
        if undoable { register(action) }
        toast = Toast(message: message, undo: undoable ? action : nil)
        await reload()
    }
}
