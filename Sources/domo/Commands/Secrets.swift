import ArgumentParser
import DomovyCore
import Foundation

struct Secrets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Scan sessions for API keys, tokens and passwords.",
        discussion: "Prints masked previews only; values are never shown, logged or saved. Codex .jsonl.zst rollouts are read but never rewritten: findings in them can only be removed by deleting the session."
    )

    @OptionGroup var options: RootOptions

    @Argument(help: "Session id or a unique prefix of it. Scans every session when left out.")
    var id: String?

    func run() async throws {
        do {
            let scans = await options.scan()
            let adapters = scans.map(\.adapter)
            let sessions: [Session]
            if let id {
                sessions = [try RootOptions.session(matching: id, in: scans).session]
            } else {
                if let error = scans.lazy.compactMap(\.error).first { throw error }
                sessions = scans.flatMap(\.sessions)
            }
            let targets = await SecretScanner.targets(for: sessions, adapters: adapters)
            let report = try await SecretScanner().scan(targets)
            print(Format.findings(report, home: options.home))
        } catch {
            throw Domo.fail(error)
        }
    }
}
