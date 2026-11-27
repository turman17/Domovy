import ArgumentParser
import DomovyCore
import Foundation

struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Undo the last `domo rm` or `domo archive`, or the one with this undo id.")

    @OptionGroup var options: RootOptions

    @Argument(help: "The undo id `domo rm` or `domo archive` printed (at least 8 characters). Defaults to the last action.")
    var undoID: String?

    @Flag(name: .long, help: "List undo entries instead of undoing.")
    var list = false

    @Flag(name: .long, help: "Print the result as JSON, for scripts and agents.")
    var json = false

    func run() async throws {
        let executor = options.executor
        if !list, undoID != nil || json {
            // The same as the MCP tool `undo`.
            let outcome = await DomovyTools(context: options.context).call("undo", arguments: ["undo_id": .string(undoID ?? "last")])
            if json { PlanRunner.printJSON(outcome.isError ? ["error": .string(outcome.text)] : outcome.structured) } else { print(outcome.text) }
            if outcome.isError { throw ExitCode.failure }
            return
        }
        do {
            if list {
                let entries = try executor.undoLog.entries()
                let records = ProcessActionLog(storeRoot: executor.storeRoot).records()
                guard !entries.isEmpty || !records.isEmpty else {
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
                if !rows.isEmpty { print(Format.table(rows, header: ["ENTRY", "WHEN", "AGENT", "SESSION", "CHANGES", "STATE"])) }
                if !records.isEmpty {
                    // Records only: Resume reverts a freeze; a quit cannot be undone.
                    let processRows = records.map { r in
                        [Format.relative(r.date), r.action.title.lowercased(), r.agent?.displayName ?? "unknown", "\(r.rootName) (pid \(r.rootPID))", r.summary]
                    }
                    print((rows.isEmpty ? "" : "\nProcess actions (records; not undone by `domo undo`):\n")
                          + Format.table(processRows, header: ["WHEN", "ACTION", "AGENT", "PROCESS", "RESULT"]))
                }
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
