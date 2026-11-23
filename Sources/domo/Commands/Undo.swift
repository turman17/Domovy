import ArgumentParser
import DomovyCore
import Foundation

struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Undo the last `domo rm` or `domo archive`.")

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "List undo entries instead of undoing.")
    var list = false

    func run() async throws {
        let executor = options.executor
        do {
            if list {
                let entries = try executor.undoLog.entries()
                guard !entries.isEmpty else {
                    print("No undo entries.")
                    return
                }
                let rows = entries.map { e in
                    [
                        e.id.uuidString.prefix(8).description,
                        Format.relative(e.createdAt),
                        e.agent.displayName,
                        String(e.sessionID.prefix(8)),
                        changes(e),
                        e.isUndone ? "undone" : e.originalsPurgedAt != nil ? "purged" : e.irreversible ? "permanent" : (e.failure == nil ? "done" : "partial"),
                    ]
                }
                print(Format.table(rows, header: ["ENTRY", "WHEN", "AGENT", "SESSION", "CHANGES", "STATE"]))
                return
            }
            for entry in try executor.undoLatestBatch() {
                let verb = entry.action == .archive ? "Decompressed" : entry.action == .redact ? "Put back the originals of" : "Restored"
                if let cleanup = CleanupID(rawValue: entry.sessionID) {
                    print("\(entry.action == .archive ? "Decompressed" : "Put back") \(cleanup.undoName).")
                } else if entry.agent.isModelStore {
                    print("Put back \(entry.sessionID) (\(entry.agent.displayName)).")
                } else if let scope = OrphanScope(rawValue: entry.sessionID) {
                    print("Put back the \(scope.rawValue) (\(entry.moved.count) items, \(entry.registryRestores.count) Desktop entries).")
                } else {
                    print("\(verb) session \(entry.sessionID) (\(entry.agent.displayName)).")
                }
            }
        } catch {
            throw Domo.fail(error)
        }
    }

    private func changes(_ entry: UndoEntry) -> String {
        switch entry.action {
        case .archive: "\(entry.compressed.count) files compressed"
        case .redact: "\(entry.redacted.reduce(0) { $0 + $1.replacements }) values redacted"
        case .delete: "\(entry.moved.count) items, \(entry.indexRestores.count + entry.registryRestores.count) index edits"
        }
    }
}
