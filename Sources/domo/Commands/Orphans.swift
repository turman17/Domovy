import ArgumentParser
import DomovyCore
import Foundation

struct Orphans: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find and clean up what Claude Code and Claude Desktop left behind.",
        discussion: """
        Orphans: companion folders and Claude Desktop entries whose transcript is gone (anything \
        changed in the last hour is left alone). With --duplicates: extra copies of a transcript \
        after a Desktop restart; the newest copy stays. Files move to the Trash (or the quarantine \
        with --to quarantine) and `domo undo` puts them back. Desktop entries change only while \
        Claude Desktop is quit.
        """
    )

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "Clean up duplicate copies instead of orphans.")
    var duplicates = false

    @Flag(name: .long, help: "Print the plan and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    @Option(name: .long, help: "Where removed files go: trash (default) or quarantine.")
    var to: Destination = .trash

    func run() async throws {
        do {
            let adapter = options.claudeCode
            guard await adapter.status() != .notInstalled else { throw AdapterError.notInstalled(.claudeCode) }
            print(Format.orphans(await adapter.orphanReport(), home: options.home))
            let plan = try await adapter.orphanPlan(duplicates ? .duplicates : .orphans, destination: to)
            guard !plan.isEmpty else {
                print("\nNothing to clean up.")
                return
            }
            print("")
            print(Format.plan(plan))
            if dryRun {
                print("\nDry run: nothing was changed.")
                return
            }
            guard !plan.liveCheck.isLive else {
                _ = try options.executor.execute(plan)
                return
            }
            if !yes {
                try confirm("\nMove \(plan.moves.count) items and \(plan.registryRemovals.count) Desktop entries (\(Format.bytes(plan.totalBytes))) to \(to.displayName)? [y/N] ")
            }
            let entry = try options.executor.execute(plan)
            print("\nDone. Moved \(entry.moved.count) items and \(entry.registryRestores.count) Desktop entries. Undo with `domo undo`.")
        } catch {
            throw Domo.fail(error)
        }
    }
}
