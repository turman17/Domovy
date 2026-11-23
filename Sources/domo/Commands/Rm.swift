import ArgumentParser
import DomovyCore
import Foundation

struct Rm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove a session and every artifact that belongs to it.",
        discussion: "Nothing is deleted permanently: items move to the Trash (or the quarantine folder with --to quarantine) and `domo undo` puts them back."
    )

    @OptionGroup var options: RootOptions

    @Argument(help: "Session id or a unique prefix of it (see `domo ls`).")
    var id: String

    @Flag(name: .long, help: "Print the plan and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    @Option(name: .long, help: "Where removed files go: trash (default) or quarantine.")
    var to: Destination = .trash

    func run() async throws {
        let adapter = options.adapter
        do {
            let session = try await adapter.session(matching: id)
            let plan = try await adapter.deletePlan(for: session, destination: to)
            print(Format.plan(plan))
            if dryRun {
                print("\nDry run: nothing was changed.")
                return
            }
            guard plan.isEmpty == false, !plan.liveCheck.isLive else {
                // The executor explains why; let it throw the typed error.
                _ = try options.executor.execute(plan)
                return
            }
            if !yes {
                try confirm("\nMove \(plan.moves.count) items (\(Format.bytes(plan.totalBytes))) to \(to.displayName)? [y/N] ")
            }
            print("")
            let entry = try options.executor.execute(plan)
            print("Done. Moved \(entry.moved.count) items and edited \(entry.indexRestores.count) index file(s). Undo with `domo undo`.")
        } catch {
            throw Domo.fail(error)
        }
    }
}

enum DomoError: Error, LocalizedError {
    case confirmationRequired
    case cancelled

    var errorDescription: String? {
        switch self {
        case .confirmationRequired: "Refusing to change anything without confirmation. Pass --yes to confirm, or --dry-run to only show the plan."
        case .cancelled: "Cancelled. Nothing was changed."
        }
    }
}

extension Destination: ExpressibleByArgument {}
