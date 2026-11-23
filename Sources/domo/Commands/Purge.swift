import ArgumentParser
import DomovyCore
import Foundation

struct Purge: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Permanently delete quarantined files that still hold secrets.",
        discussion: "This is the only permanent delete in Domovy. It lists exactly which files go, asks first, and cannot be undone."
    )

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "Originals kept by `domo redact`.")
    var redactedOriginals = false

    @Flag(name: .long, help: "Sessions moved to the quarantine after the secret scan flagged them.")
    var flaggedSessions = false

    @Flag(name: .long, help: "Print what would be deleted and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    func validate() throws {
        guard redactedOriginals || flaggedSessions else {
            throw ValidationError("Say what to purge: --redacted-originals and/or --flagged-sessions.")
        }
    }

    func run() async throws {
        do {
            var reasons: Set<PurgeItem.Reason> = []
            if redactedOriginals { reasons.insert(.redactedOriginal) }
            if flaggedSessions { reasons.insert(.flaggedSession) }
            let executor = options.executor
            let plan = try executor.purgePlan(reasons)
            for item in plan.items {
                print("  \(Format.bytes(item.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(item.file.path)")
                print("  \(String(repeating: " ", count: 10)) \(item.reason == .redactedOriginal ? "original of" : "deleted from") \(item.originalPath.path)")
            }
            print((plan.items.isEmpty ? "" : "\n") + plan.summary)
            guard !plan.isEmpty, !dryRun else {
                if dryRun { print("\nDry run: nothing was changed.") }
                return
            }
            if !yes {
                try confirm("\nPermanently delete these \(plan.items.count) file(s)? This cannot be undone. [y/N] ")
            }
            try executor.purge(plan)
            print("\nDeleted \(plan.items.count) file(s) for good.")
        } catch {
            throw Domo.fail(error)
        }
    }
}
