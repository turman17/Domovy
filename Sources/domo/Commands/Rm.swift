import ArgumentParser
import DomovyCore
import Foundation

struct Rm: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove sessions and every artifact that belongs to them.",
        discussion: """
        Name sessions by id, or select them with --older, --agent and --project (live sessions are never \
        selected). Nothing is deleted permanently: items move to the Trash (or the quarantine folder with \
        --to quarantine) and `domo undo` puts them back. Live sessions and sessions written to in the last \
        10 minutes are refused. For scripts and agents: `--dry-run --json` prints the plan with a plan \
        digest; `-y --if-plan <digest>` runs it only if it is still that plan.
        """
    )

    @OptionGroup var options: RootOptions

    @Argument(help: "Session ids or unique prefixes of them (see `domo ls`).")
    var ids: [String] = []

    @OptionGroup var filters: SessionFilters

    @OptionGroup var flags: PlanFlags

    @Option(name: .long, help: "Where removed files go: trash or quarantine. Defaults to the Settings choice (the Trash unless changed).")
    var to: Destination?

    @Flag(name: .long, help: "Accept that undo may stop working (OpenCode, Cursor: once the app writes to its database again). Required with --yes for such plans.")
    var acceptLimitedUndo = false

    func run() async throws {
        do {
            let ids = try await options.sessionIDs(ids, filters: filters)
            try await PlanRunner.run(.delete, sessionIDs: ids, destination: options.destination(to), flags: flags,
                                     acceptLimitedUndo: acceptLimitedUndo, options: options)
        } catch let error as ExitCode {
            throw error
        } catch let error as ValidationError {
            throw error
        } catch {
            throw Domo.fail(error)
        }
    }
}

enum DomoError: Error, LocalizedError {
    case confirmationRequired
    case cancelled
    case acknowledgementRequired
    case message(String)

    var errorDescription: String? {
        switch self {
        case .confirmationRequired: "Refusing to change anything without confirmation. Pass --yes to confirm, or --dry-run to only show the plan."
        case .cancelled: "Cancelled. Nothing was changed."
        case .acknowledgementRequired: "Nothing was changed: undo of this delete may stop working (see above). Pass --accept-limited-undo with --yes to go ahead."
        case .message(let text): text
        }
    }
}

extension Destination: ExpressibleByArgument {}
