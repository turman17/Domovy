import ArgumentParser
import DomovyCore
import Foundation

struct Secrets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan sessions for API keys, tokens and passwords.",
        discussion: "Prints masked previews only; values are never shown, logged or saved. Codex .jsonl.zst rollouts are skipped."
    )

    @OptionGroup var options: RootOptions

    @Argument(help: "Session id or a unique prefix of it. Scans every session when left out.")
    var id: String?

    func run() async throws {
        do {
            let adapters = await options.installedAdapters()
            let sessions: [Session]
            if let id {
                sessions = [try await options.session(matching: id).session]
            } else {
                var all: [Session] = []
                for adapter in adapters { all += try await adapter.sessions() }
                sessions = all
            }
            let targets = await SecretScanner.targets(for: sessions, adapters: adapters)
            let report = try await SecretScanner().scan(targets)
            print(Format.findings(report, home: options.home))
        } catch {
            throw Domo.fail(error)
        }
    }
}
