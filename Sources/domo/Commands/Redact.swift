import ArgumentParser
import DomovyCore
import Foundation

struct Redact: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replace the secrets found in a session with [REDACTED:<rule>].",
        discussion: "The original files, with the secrets, are kept in Domovy's quarantine so `domo undo` can put them back. Remove them for good with `domo purge --redacted-originals`."
    )

    @OptionGroup var options: RootOptions

    @Argument(help: "Session id or a unique prefix of it (see `domo ls`).")
    var id: String

    @Flag(name: .long, help: "Print the plan and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    func run() async throws {
        do {
            let (adapter, session) = try await options.session(matching: id)
            let report = try await SecretScanner().scan(session, adapter: adapter)
            let plan = try await RedactionPlanner.plan(for: session, findings: report.findings, adapter: adapter)
            print(Format.plan(plan))
            if dryRun {
                print("\nDry run: nothing was changed.")
                return
            }
            guard !plan.isEmpty, !plan.liveCheck.isLive else {
                _ = try options.executor.execute(plan)
                return
            }
            if !yes {
                try confirm("\nRedact \(plan.redactionCount) values in \(plan.redactions.count) file(s)? [y/N] ")
            }
            let entry = try options.executor.execute(plan)
            let n = entry.redacted.reduce(0) { $0 + $1.replacements }
            print("\nDone. Redacted \(n) \(n == 1 ? "value" : "values") in \(entry.redacted.count) file(s). Undo with `domo undo`; remove the originals with `domo purge --redacted-originals`.")
        } catch {
            throw Domo.fail(error)
        }
    }
}
