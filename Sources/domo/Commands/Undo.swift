import ArgumentParser
import DomovyCore
import Foundation

struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Put back what the last `domo rm` moved.")

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
                        "\(e.moved.count) items, \(e.indexRestores.count) index edits",
                        e.isUndone ? "undone" : (e.failure == nil ? "done" : "partial"),
                    ]
                }
                print(Format.table(rows, header: ["ENTRY", "WHEN", "AGENT", "SESSION", "CHANGES", "STATE"]))
                return
            }
            let entry = try executor.undoLatest()
            print("Restored session \(entry.sessionID) (\(entry.agent.displayName)).")
        } catch {
            throw Domo.fail(error)
        }
    }
}
