import ArgumentParser
import DomovyCore
import Foundation

extension CleanupID: ExpressibleByArgument {}

struct Clean: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run a guided Disk cleanup. List the ids with `domo du --ids`.",
        discussion: """
        Moves the category's files to the Trash (or the quarantine with --to quarantine); \
        codex-large-rollouts compresses them in place instead. `domo undo` puts everything back. \
        Refuses while the owning app runs or anything has the files open. Worktrees move only \
        when git says they are clean and their commits are on another branch.
        """
    )

    @Argument(help: "Category id: \(CleanupID.allCases.map(\.rawValue).joined(separator: ", ")).")
    var category: CleanupID

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "Print the plan and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    @Option(name: .long, help: "Where removed files go: trash or quarantine. Defaults to the Settings choice (the Trash unless changed).")
    var to: Destination?

    func run() async throws {
        do {
            let to = options.destination(self.to)
            let planner = options.cleanupPlanner
            let cleanup = try await planner.plan(category, destination: to)
            print(Format.cleanup(cleanup, home: options.home))
            if dryRun {
                print("\nDry run: nothing was changed.")
                return
            }
            guard !cleanup.isBlocked else { throw CleanupError.inUse(reasons: cleanup.plan.liveCheck.reasons) }
            guard !cleanup.plan.isEmpty else {
                print("\nNothing to do.")
                return
            }
            if !yes {
                let what = !cleanup.plan.commands.isEmpty
                    ? "Run \(cleanup.plan.commands.map { "`\($0.commandLine)`" }.joined(separator: ", "))\(cleanup.plan.isPermanent ? " (Domovy keeps a copy first)" : "")"
                    : category.compresses ? "Compress \(cleanup.plan.compressions.count) file(s) in place" : "Move \(cleanup.plan.moves.count) item(s) (\(Format.bytes(cleanup.plan.totalBytes))) to \(to.displayName)"
                try confirm("\n\(what)? [y/N] ")
            }
            let entry = try await planner.execute(cleanup, with: options.executor)
            let n = category.compresses ? entry.compressed.count : entry.moved.count
            let done = !cleanup.plan.commands.isEmpty
                ? "Ran \(cleanup.plan.commands.map { "`\($0.commandLine)`" }.joined(separator: ", "))"
                : category.compresses ? "Compressed \(n) \(n == 1 ? "file" : "files")" : "Moved \(n) \(n == 1 ? "item" : "items")"
            print("\nDone. \(done).\(entry.irreversible ? "" : " Undo with `domo undo`.")")
            Domo.printLeftovers([entry])
        } catch {
            throw Domo.fail(error)
        }
    }
}
