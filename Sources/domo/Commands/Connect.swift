import ArgumentParser
import DomovyCore
import Foundation

/// Options `connect` and `disconnect` share.
struct ConnectOptions: ParsableArguments {
    @OptionGroup var root: RootOptions

    @Option(name: .long, parsing: .upToNextOption, help: "Only these agents (\(ConnectAgent.allCases.map(\.rawValue).joined(separator: ", "))).")
    var agent: [String] = []

    @Flag(name: .long, help: "Every detected agent (the default when no --agent is given).")
    var all = false

    @Flag(name: .long, help: "Print what would change and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Skip the confirmation prompt. Required when stdin is not a terminal.")
    var yes = false

    func agents() throws -> [ConnectAgent]? {
        guard !agent.isEmpty, !all else { return nil }
        return try agent.map { name in
            guard let found = ConnectAgent.parse(name) else { throw ValidationError("Unknown agent \(name). Known: \(ConnectAgent.allCases.map(\.rawValue).joined(separator: ", "))") }
            return found
        }
    }

    var connector: AgentConnector {
        AgentConnector(home: root.home, isCustomHome: root.root != nil)
    }

    func run(_ mode: ConnectPlan.Mode, command: [String]) throws {
        let plan = connector.plan(mode, command: command, agents: try agents())
        try ConnectOutput(home: root.home, connector: connector).apply(plan, dryRun: dryRun, yes: yes)
    }
}

/// Prints a connect or disconnect plan, asks, executes and reports. `domo install` shares it.
struct ConnectOutput {
    let home: URL
    let connector: AgentConnector

    /// Prints each agent's state and steps, asks unless `yes`, then executes and reports.
    func apply(_ plan: ConnectPlan, dryRun: Bool, yes: Bool) throws {
        let mode = plan.mode, command = plan.command
        if mode == .connect { print("Server command: \(command.joined(separator: " "))\n") }
        for item in plan.agents {
            let state: String = switch item.state {
            case .willChange: mode == .connect ? "will connect" : "will disconnect"
            case .upToDate: mode == .connect ? "already connected" : "not connected"
            case .notDetected: "not found"
            case .refused(let reason): "refused: \(reason)"
            }
            print("\(item.agent.displayName): \(state)")
            for step in item.steps {
                print("  - \(step.description(home: home))")
                if dryRun {
                    let manual = step.manual(home: home, domo: command.first)
                    print(manual.text.split(separator: "\n", omittingEmptySubsequences: false).map { "      " + $0 }.joined(separator: "\n"))
                }
            }
            for note in item.notes where item.state == .willChange || item.state == .upToDate { print("  \(note)") }
        }
        guard plan.hasChanges else {
            print("\nNothing to change.")
            return
        }
        if dryRun {
            print("\nDry run: nothing was changed.")
            return
        }
        if !yes {
            let count = plan.agents.filter { $0.state == .willChange }.count
            try confirm("\n\(mode == .connect ? "Connect" : "Disconnect") \(count) \(count == 1 ? "agent" : "agents")? Config files are backed up first. [y/N] ")
        }
        print("")
        var failed = false
        for result in connector.execute(plan) {
            switch result.outcome {
            case .changed: print("\(result.agent.displayName): \(mode == .connect ? "connected" : "disconnected")")
            case .unchanged: break
            case .failed(let reason):
                failed = true
                print("\(result.agent.displayName): failed: \(reason)")
            }
        }
        if mode == .connect { print("\nBackups of changed config files are in Domovy's folder (Connect/Backups). `domo disconnect` removes exactly what was added. After upgrading domo, run `domo update`.") }
        if failed { throw ExitCode.failure }
    }
}

struct Connect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Register Domovy's MCP server and skill with your AI agents.",
        discussion: """
        For each detected agent (\(ConnectAgent.allCases.map(\.displayName).joined(separator: ", "))): adds a \
        "domovy" MCP server that runs `domo mcp`, and the domovy skill in a skills folder the agent reads \
        (never a shared rules file such as CLAUDE.md or AGENTS.md). Uses the agent's own `mcp add` command \
        where it has one; otherwise edits its config file in place, keeping every other byte. Never touches \
        auth files. `--dry-run` prints each change as a command or file snippet you can apply by hand.
        """
    )

    @OptionGroup var options: ConnectOptions

    @Option(name: .long, help: "The domo executable agents should run. Defaults to this one, by the path you ran it from.")
    var command: String?

    @Flag(name: .long, help: "Print the domovy SKILL.md that connect installs, and change nothing.")
    var printSkill = false

    @Flag(name: .long, help: "Print the skill's references.md, and change nothing.")
    var printSkillReferences = false

    func run() async throws {
        do {
            let command = try options.root.serverCommand(override: command)
            if printSkill || printSkillReferences {
                print(DomovySkill.files(command: command)[printSkill ? "SKILL.md" : "references.md"] ?? "", terminator: "")
                return
            }
            try options.run(.connect, command: command)
        } catch let error as ExitCode {
            throw error
        } catch let error as ValidationError {
            throw error
        } catch {
            throw Domo.fail(error)
        }
    }
}

extension RootOptions {
    /// `domo mcp` as agents should run it: this executable (or `override`), `--root` for a custom home.
    func serverCommand(override: String? = nil) throws -> [String] {
        guard let domo = MCPRegistration.domoExecutable(override: override, running: MCPRegistration.invokedExecutable()) else {
            throw ValidationError("Could not find this domo executable; pass --command <path>.")
        }
        return MCPRegistration.serverCommand(domo: domo, home: home, isCustomHome: root != nil)
    }
}

struct Disconnect: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Remove Domovy's MCP server and skill from your AI agents.",
        discussion: "Removes exactly what `domo connect` added. A skill folder shared by several agents stays while one of them is still connected."
    )

    @OptionGroup var options: ConnectOptions

    func run() async throws {
        do {
            try options.run(.disconnect, command: [])
        } catch let error as ExitCode {
            throw error
        } catch let error as ValidationError {
            throw error
        } catch {
            throw Domo.fail(error)
        }
    }
}
