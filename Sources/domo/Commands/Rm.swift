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

    @Flag(name: .long, help: "Accept that undo may stop working (OpenCode: once it writes to its database again). Required with --yes for such plans.")
    var acceptLimitedUndo = false

    func run() async throws {
        do {
            let (adapter, session) = try await options.session(matching: id)
            var plan = try await adapter.deletePlan(for: session, destination: to)
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
            if plan.acknowledgement != nil, yes, !acceptLimitedUndo { throw DomoError.acknowledgementRequired }
            if !yes {
                var steps = plan.commands.map { "run `\($0.commandLine)`" }
                if !plan.moves.isEmpty || steps.isEmpty {
                    steps.append("move \(plan.moves.count) items (\(Format.bytes(plan.totalBytes))) to \(to.displayName)")
                }
                let question = steps.joined(separator: " and ")
                let accept = plan.acknowledgement.map { " \($0) Continue anyway?" } ?? ""
                try confirm("\n\(question.prefix(1).uppercased() + question.dropFirst())?\(accept) [y/N] ")
            }
            // A yes at the prompt (or --accept-limited-undo) is the explicit OK.
            plan.isAcknowledged = true
            print("")
            let entry = try options.executor.execute(plan)
            let ran = plan.commands.isEmpty ? "" : "Ran \(plan.commands.map { "`\($0.commandLine)`" }.joined(separator: ", ")). "
            print("Done. \(ran)Moved \(entry.moved.count) items and edited \(entry.indexRestores.count) index file(s). Undo with `domo undo`.")
            Domo.printLeftovers([entry])
        } catch {
            throw Domo.fail(error)
        }
    }
}

enum DomoError: Error, LocalizedError {
    case confirmationRequired
    case cancelled
    case acknowledgementRequired

    var errorDescription: String? {
        switch self {
        case .confirmationRequired: "Refusing to change anything without confirmation. Pass --yes to confirm, or --dry-run to only show the plan."
        case .cancelled: "Cancelled. Nothing was changed."
        case .acknowledgementRequired: "Nothing was changed: undo of this delete may stop working (see above). Pass --accept-limited-undo with --yes to go ahead."
        }
    }
}

extension Destination: ExpressibleByArgument {}
