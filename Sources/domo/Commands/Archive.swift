import ArgumentParser
import DomovyCore
import Foundation

struct Archive: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Compress cold sessions in place so they take less disk.",
        discussion: """
        Uses APFS transparent compression: Claude Code reads the files unchanged and can still resume the session. \
        Modification times are kept, so Claude Code's own cleanup still applies on schedule. `domo undo` decompresses again.
        """
    )

    @OptionGroup var options: RootOptions

    @Argument(help: "Session id or a unique prefix of it (see `domo ls`).")
    var id: String?

    @Option(name: .long, help: "Archive every idle session last active longer ago than this (e.g. 30d, 2w).")
    var older: AgeThreshold?

    @Flag(name: .long, help: "Print the plan and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    func validate() throws {
        guard (id == nil) != (older == nil) else {
            throw ValidationError("Pass either a session id or --older <age>, not both.")
        }
    }

    func run() async throws {
        let adapter = options.adapter
        do {
            let plans: [Plan]
            if let id {
                let plan = try await adapter.archivePlan(for: try await adapter.session(matching: id))
                print(Format.plan(plan))
                plans = [plan]
            } else {
                plans = try await batchPlans(adapter)
            }
            if dryRun {
                print("\nDry run: nothing was changed.")
                return
            }
            let runnable = plans.filter { !$0.isEmpty && !$0.liveCheck.isLive }
            guard !runnable.isEmpty else {
                if let plan = plans.first, plans.count == 1 {
                    _ = try options.executor.execute(plan) // explains why: live or nothing to do
                }
                print("\nNothing to archive.")
                return
            }
            let files = runnable.reduce(0) { $0 + $1.compressions.count }
            let bytes = runnable.reduce(Int64(0)) { $0 + $1.totalBytes }
            if !yes {
                try confirm("\nCompress \(files) files (\(Format.bytes(bytes))) in \(runnable.count) \(runnable.count == 1 ? "session" : "sessions")? [y/N] ")
            }
            let entries = try options.executor.execute(runnable)
            let done = entries.reduce(0) { $0 + $1.compressed.count }
            if done < files { print("\nLeft \(files - done) files as they were: they changed since planning or did not compress.") }
            print("\nDone. Compressed \(done) files in \(entries.count) \(entries.count == 1 ? "session" : "sessions"). Undo with `domo undo`.")
        } catch {
            throw Domo.fail(error)
        }
    }

    /// One plan per idle, not yet archived session older than the threshold, with a short table.
    private func batchPlans(_ adapter: ClaudeCodeAdapter) async throws -> [Plan] {
        guard let older else { return [] }
        let cutoff = Date().addingTimeInterval(-older.seconds)
        let candidates = try await adapter.sessions().filter { $0.lastActive < cutoff && $0.status != .live }
        var plans: [Plan] = []
        var rows: [[String]] = []
        for session in candidates {
            let plan = try await adapter.archivePlan(for: session)
            plans.append(plan)
            let state = plan.liveCheck.isLive ? "live, skipped" : (plan.isEmpty ? "nothing to compress" : "\(plan.compressions.count) files")
            rows.append([
                String(session.id.prefix(8)),
                Format.relative(session.lastActive),
                Format.bytes(plan.totalBytes),
                plan.isEmpty ? "-" : "~" + Format.bytes(plan.estimatedBytesAfter),
                state,
                session.title ?? "(no prompt found)",
            ])
        }
        guard !rows.isEmpty else {
            print("No idle sessions older than \(older.text).")
            return []
        }
        print(Format.table(rows, header: ["ID", "LAST ACTIVE", "SIZE", "AFTER", "FILES", "TITLE"], rightAligned: [2, 3]))
        let runnable = plans.filter { !$0.isEmpty && !$0.liveCheck.isLive }
        guard !runnable.isEmpty else { return plans }
        let before = runnable.reduce(Int64(0)) { $0 + $1.totalBytes }
        let after = runnable.reduce(Int64(0)) { $0 + $1.estimatedBytesAfter }
        print("\n\(runnable.count) \(runnable.count == 1 ? "session" : "sessions"): \(Format.bytes(before)) \u{2192} ~\(Format.bytes(after)). Claude Code can still resume them. You can undo this.")
        return plans
    }
}

/// "30d", "2w" or "12h".
struct AgeThreshold: ExpressibleByArgument {
    let seconds: TimeInterval
    let text: String

    init?(argument: String) {
        let units: [Character: TimeInterval] = ["h": 3_600, "d": 86_400, "w": 604_800]
        guard let unit = argument.last, let factor = units[unit], let value = Double(argument.dropLast()), value > 0 else { return nil }
        seconds = value * factor
        text = argument
    }
}
