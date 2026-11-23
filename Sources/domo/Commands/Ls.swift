import ArgumentParser
import DomovyCore
import Foundation

struct Ls: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List agent sessions.")

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "Print full session ids instead of the first 8 characters.")
    var full = false

    func run() async throws {
        var sessions: [Session] = []
        do {
            for adapter in await options.installedAdapters() {
                if case .readOnly(let reason) = await adapter.status() {
                    FileHandle.standardError.write(Data("note: \(adapter.kind.displayName) is read-only: \(reason)\n".utf8))
                }
                sessions += try await adapter.sessions()
            }
        } catch {
            throw Domo.fail(error)
        }
        sessions.sort { $0.lastActive > $1.lastActive }
        guard !sessions.isEmpty else {
            print("No sessions found. All tidy.")
            return
        }
        let rows = sessions.map { s in
            [
                full ? s.id : String(s.id.prefix(8)),
                s.agent.displayName,
                s.projectName ?? "-",
                Format.relative(s.lastActive),
                Format.bytes(s.sizeBytes),
                Format.status(s),
                s.title ?? "(no prompt found)",
            ]
        }
        print(Format.table(rows, header: ["ID", "AGENT", "PROJECT", "LAST ACTIVE", "SIZE", "STATUS", "TITLE"], rightAligned: [4]))
    }
}
