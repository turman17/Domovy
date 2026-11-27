import ArgumentParser
import DomovyCore
import Foundation

struct Leftovers: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Find leftover agent worktrees and build output in the projects agents worked in.",
        discussion: """
        Looks at the sessions' project folders and the agents' worktree folders, never your whole \
        home. A worktree is a leftover when nothing uses it, git shows no uncommitted or ignored \
        work in it, and its commits are on a branch; the branch stays. Build output (node_modules, \
        .build, target, dist, .next, __pycache__, .venv, DerivedData) counts only when git ignores it. \
        With --clean, leftovers and build output in agent worktrees move to the Trash (or the \
        quarantine with --to quarantine); --main-checkouts adds build output of main checkouts. \
        `domo undo` puts everything back. Worktrees with uncommitted work are never removed here.
        """
    )

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "Remove the leftovers instead of only listing them.")
    var clean = false

    @Flag(name: .long, help: "With --clean: also remove build output in main checkouts and plain project folders.")
    var mainCheckouts = false

    @Flag(name: .long, help: "Print the plan and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    @Option(name: .long, help: "Where removed folders go: trash or quarantine. Defaults to the Settings choice (the Trash unless changed).")
    var to: Destination?

    func run() async throws {
        do {
            let to = options.destination(self.to)
            let sessions = await options.scan().flatMap(\.sessions)
            let scanner = LeftoverScanner(home: options.home)
            let report = await scanner.scan(sessions: sessions)
            print(Self.format(report, home: options.home))
            guard clean || dryRun, !report.isEmpty else { return }
            var selection = report.defaultSelection
            if mainCheckouts { selection.formUnion(report.buildOutputs.filter(\.isRemovable).map(\.url)) }
            let leftover = await scanner.plan(selection, in: report, sessions: sessions, destination: to)
            print("")
            print(Format.plan(leftover.plan).replacingOccurrences(of: "\n" + leftover.plan.summary, with: "\n" + leftover.summary))
            if dryRun {
                print("\nDry run: nothing was changed.")
                return
            }
            guard !leftover.isBlocked else { throw CleanupError.inUse(reasons: leftover.plan.liveCheck.reasons) }
            guard !leftover.plan.isEmpty else {
                print("\nNothing to do.")
                return
            }
            if !yes { try confirm("\nMove \(leftover.plan.moves.count) folder(s) (\(Format.bytes(leftover.plan.totalBytes))) to \(to.displayName)? [y/N] ") }
            let entry = try await scanner.execute(leftover, with: options.executor)
            print("\nDone. Moved \(entry.moved.count) \(entry.moved.count == 1 ? "folder" : "folders"). Undo with `domo undo`.")
        } catch {
            throw Domo.fail(error)
        }
    }

    static func format(_ report: LeftoverReport, home: URL) -> String {
        guard !report.isEmpty else { return "No leftover agent worktrees or build output found." }
        var lines = ["\(Format.bytes(report.reclaimableBytes)) can be freed."]
        for group in report.groups {
            lines.append("")
            lines.append("\(group.name)  \(path(group.root, home: home))  \(Format.bytes(group.reclaimableBytes)) to free")
            for worktree in group.worktrees {
                let mark = switch worktree.state {
                case .leftover: "leftover"
                case .hasWork: "HAS WORK"
                case .inUse: "in use"
                case .keep: "keep"
                }
                let agent = worktree.agent.map { " (\($0.displayName))" } ?? ""
                lines.append("  \(mark.padding(toLength: 9, withPad: " ", startingAt: 0)) \(Format.bytes(worktree.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(path(worktree.url, home: home))\(agent)")
                lines.append("  \(String(repeating: " ", count: 20)) \(worktree.state.reason)")
            }
            for output in group.buildOutputs {
                let mark = output.isRemovable ? "build" : "in use"
                lines.append("  \(mark.padding(toLength: 9, withPad: " ", startingAt: 0)) \(Format.bytes(output.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0)) \(path(output.url, home: home))")
                lines.append("  \(String(repeating: " ", count: 20)) \(output.inUse ?? "Safe: rebuildable. " + output.kind.explanation)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `~/code/orbit-api` below the home folder, the full path elsewhere.
    private static func path(_ url: URL, home: URL) -> String {
        let base = home.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        return full.hasPrefix(base + "/") ? "~/" + full.dropFirst(base.count + 1) : full
    }
}
