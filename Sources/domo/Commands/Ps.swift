import ArgumentParser
import DomovyCore
import Foundation

/// Agent processes: `domo ps`, and `freeze`, `resume`, `quit` for one process tree.
extension RootOptions {
    var processWatcher: ProcessWatcher {
        ProcessWatcher(sessions: ProcessSessionResolver(home: home), herdr: HerdrClient.at(home: home, isCustomHome: root != nil))
    }

    /// Herdr's panes and agents, so a session running in one is refused and says where.
    var herdr: HerdrState {
        HerdrClient.at(home: home, isCustomHome: root != nil).state() ?? .empty
    }

    var processController: ProcessController {
        ProcessController(log: ProcessActionLog(storeRoot: executor.storeRoot))
    }

    /// Two samples a second apart, so CPU shares are filled in.
    func processReport() async throws -> ProcessReport {
        guard let report = await processWatcher.sampled(over: 1) else { throw ProcessActionError.unreadable }
        return report
    }
}

struct Ps: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List agent processes: each agent's tree, likely MCP servers, and orphans.",
        discussion: "Reads the process table only. Command lines are never printed; MCP servers are named by their package."
    )

    @OptionGroup var options: RootOptions

    @Flag(name: .long, help: "Only orphaned processes: started by an agent that is gone.")
    var orphans = false

    @Flag(name: .long, help: "Print JSON.")
    var json = false

    func run() async throws {
        do {
            let report = try await options.processReport()
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                let value = orphans ? ProcessReport(groups: [], orphans: report.orphans, takenAt: report.takenAt) : report
                print(String(decoding: try encoder.encode(value), as: UTF8.self))
                return
            }
            var rows: [[String]] = []
            func add(_ node: ProcessNode, depth: Int, title: String? = nil) {
                let indent = String(repeating: "  ", count: depth)
                rows.append([
                    String(node.pid), node.agent?.displayName ?? "unknown", node.kind.displayName.lowercased(),
                    indent + (title ?? node.name), node.footprintBytes.map(Format.memory) ?? "–",
                    node.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "–", Format.state(node),
                ])
                for child in node.children { add(child, depth: depth + 1) }
            }
            if !orphans {
                // Agents in Herdr first, by workspace and pane; the rest after, largest first.
                for group in report.groups.sorted(by: Self.herdrOrder) {
                    let sessions = group.sessionIDs.map { String($0.prefix(8)) }
                    let pane = group.herdr.map { " · Herdr \($0.title)" } ?? ""
                    add(group.root, depth: 0, title: group.root.name + (sessions.isEmpty ? "" : " · " + sessions.joined(separator: ", ")) + pane)
                }
            }
            for orphan in report.orphans { add(orphan, depth: 0) }
            if !rows.isEmpty {
                print(Format.table(rows, header: ["PID", "AGENT", "KIND", "NAME", "MEMORY", "CPU", "STATE"], rightAligned: [0, 4, 5]))
                print("")
            }
            let orphanText = report.orphanCount == 0 ? "no orphans" : "\(report.orphanCount) orphaned (\(Format.memory(report.orphanBytes)))"
            print(orphans
                ? "\(orphanText.prefix(1).uppercased() + orphanText.dropFirst())."
                : "\(report.processCount) agent processes, \(Format.memory(report.totalBytes)) memory, \(orphanText).")
            if !report.orphans.isEmpty { print("Quit an orphan with `domo quit <pid>`; freeze any process tree with `domo freeze <pid>`.") }
        } catch {
            throw Domo.fail(error)
        }
    }
}

extension Ps {
    static func herdrOrder(_ a: ProcessGroup, _ b: ProcessGroup) -> Bool {
        switch (a.herdr, b.herdr) {
        case let (x?, y?): (x.workspaceLabel, x.paneID) < (y.workspaceLabel, y.paneID)
        case (.some, nil): true
        case (nil, .some): false
        case (nil, nil): a.root.totalBytes > b.root.totalBytes
        }
    }
}

/// Shared by freeze, resume and quit: show the plan, confirm, signal, report.
struct ProcessActionOptions: ParsableArguments {
    @Argument(help: "Process id (see `domo ps`). Everything it started is included.")
    var pid: Int32

    @Flag(name: .long, help: "Print the plan and signal nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    /// Returns the result, or `nil` for a dry run.
    func run(_ action: ProcessAction, options: RootOptions) async throws -> (ProcessActionPlan, ProcessActionResult)? {
        let report = try await options.processReport()
        let controller = options.processController
        let plan = try controller.plan(action, pid: pid, in: report)
        print(Format.processPlan(plan))
        guard plan.canExecute else {
            if let suggestion = plan.suggestion { print("Try `domo \(suggestion.rawValue) \(pid)`.") }
            throw ProcessActionError.refused(plan.refusals)
        }
        if dryRun {
            print("\nDry run: nothing was signaled.")
            return nil
        }
        if !yes { try confirm("\n\(action.title) \(plan.targets.count) process(es)? [y/N] ") }
        let result = try await controller.execute(plan)
        print("\n" + result.summary)
        return (plan, result)
    }
}

struct Freeze: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pause a process tree (SIGSTOP). It keeps its memory; `domo resume` lets it run again."
    )

    @OptionGroup var options: RootOptions
    @OptionGroup var action: ProcessActionOptions

    func run() async throws {
        do { _ = try await action.run(.freeze, options: options) } catch { throw Domo.fail(error) }
    }
}

struct Resume: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Let a frozen process tree run again (SIGCONT).")

    @OptionGroup var options: RootOptions
    @OptionGroup var action: ProcessActionOptions

    func run() async throws {
        do { _ = try await action.run(.resume, options: options) } catch { throw Domo.fail(error) }
    }
}

struct Quit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Ask an orphaned process tree to exit (SIGTERM).",
        discussion: "Only orphans: processes whose agent is gone. An agent or a process it still uses is refused; freeze it instead. With --force, whatever is still running after a few seconds is ended with SIGKILL, after a second confirmation."
    )

    @OptionGroup var options: RootOptions
    @OptionGroup var action: ProcessActionOptions

    @Flag(name: .long, help: "If processes are still running after the wait, end them with SIGKILL (asks again).")
    var force = false

    func run() async throws {
        do {
            guard let (plan, result) = try await action.run(.quit, options: options) else { return }
            guard !result.stillRunning.isEmpty else { return }
            guard force else {
                print("Run again with --force to end them with SIGKILL.")
                return
            }
            let controller = options.processController
            let kill = controller.forceQuitPlan(after: result, of: plan)
            print("\n" + kill.summary)
            if !action.yes { try confirm("\nForce quit \(kill.targets.count) process(es)? This cannot be undone. [y/N] ") }
            print("\n" + (try await controller.execute(kill)).summary)
        } catch {
            throw Domo.fail(error)
        }
    }
}
