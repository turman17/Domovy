import ArgumentParser
import DomovyCore
import Foundation

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Choose the agents to connect to Domovy (MCP server and skill).",
        discussion: """
        In a terminal, shows every detected agent, all checked, with what connecting it changes: \
        space toggles, enter applies. Without a terminal, pass --yes to connect every detected agent \
        (the same as `domo connect --all --yes`). --refresh rewrites the skill and re-registers the \
        server for the agents that already have Domovy, with this domo's path; `domo update` does the same.
        """
    )

    @OptionGroup var options: RootOptions

    @Option(name: .long, help: "The domo executable agents should run. Defaults to this one, by the path you ran it from.")
    var command: String?

    @Flag(name: .long, help: "Update the agents that already have Domovy, and connect no new ones.")
    var refresh = false

    @Flag(name: .long, help: "Print what would change and change nothing.")
    var dryRun = false

    @Flag(name: [.customShort("y"), .long], help: "Connect every detected agent without the picker. Required when stdin is not a terminal.")
    var yes = false

    func run() async throws {
        do {
            let command = try options.serverCommand(override: command)
            let connector = AgentConnector(home: options.home, isCustomHome: options.root != nil)
            let output = ConnectOutput(home: options.home, connector: connector)
            if refresh {
                try Self.refresh(connector, command: command, dryRun: dryRun, output: output)
                return
            }
            let plan = connector.plan(.connect, command: command)
            guard !plan.agents.isEmpty else {
                print("No agents found here. Domovy connects \(ConnectAgent.allCases.map(\.displayName).joined(separator: ", ")).")
                return
            }
            guard !dryRun, !yes, isatty(STDIN_FILENO) != 0, isatty(STDOUT_FILENO) != 0 else {
                // No picker: --yes applies the picker's default (every detected agent).
                let chosen = InstallPicker(plan: plan).chosen
                try output.apply(connector.plan(.connect, command: command, agents: chosen), dryRun: dryRun, yes: yes)
                return
            }
            var picker = InstallPicker(plan: plan)
            guard case .apply(let chosen) = Terminal.pick(&picker, home: options.home) else {
                print("Cancelled. Nothing was changed.")
                return
            }
            guard !chosen.isEmpty else {
                print("No agent chosen. Nothing was changed.")
                return
            }
            // Enter on the picker, which showed every change, is the confirmation.
            try output.apply(connector.plan(.connect, command: command, agents: chosen), dryRun: false, yes: true)
        } catch let error as ExitCode {
            throw error
        } catch let error as ValidationError {
            throw error
        } catch {
            throw Domo.fail(error)
        }
    }

    /// Re-registers and rewrites the skill for the agents that have Domovy now. Only what is
    /// already installed changes, so it does not ask.
    static func refresh(_ connector: AgentConnector, command: [String], dryRun: Bool, output: ConnectOutput) throws {
        let plan = connector.refreshPlan(command: command)
        guard !plan.agents.isEmpty else {
            print("No agent has Domovy yet. Run `domo install` to choose some.")
            return
        }
        try output.apply(plan, dryRun: dryRun, yes: true)
    }
}

struct Update: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "After upgrading domo: rewrite the skill and re-register the server for the agents that have Domovy.",
        discussion: "The same as `domo install --refresh`. Upgrade domo itself with `brew upgrade domo` or a new Domovy.app.",
        aliases: ["upgrade"]
    )

    @OptionGroup var options: RootOptions

    @Option(name: .long, help: "The domo executable agents should run. Defaults to this one, by the path you ran it from.")
    var command: String?

    @Flag(name: .long, help: "Print what would change and change nothing.")
    var dryRun = false

    func run() async throws {
        do {
            let command = try options.serverCommand(override: command)
            let connector = AgentConnector(home: options.home, isCustomHome: options.root != nil)
            try Install.refresh(connector, command: command, dryRun: dryRun, output: ConnectOutput(home: options.home, connector: connector))
        } catch let error as ExitCode {
            throw error
        } catch let error as ValidationError {
            throw error
        } catch {
            throw Domo.fail(error)
        }
    }
}

/// Raw terminal input for the install picker.
enum Terminal {
    /// Draws the picker and reads keys until the user applies or cancels. Restores the terminal.
    static func pick(_ picker: inout InstallPicker, home: URL) -> InstallPicker.Outcome {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return .cancel }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        print("\u{1B}[?25l", terminator: "") // hide the cursor
        defer {
            tcsetattr(STDIN_FILENO, TCSANOW, &original)
            print("\u{1B}[?25h", terminator: "")
            fflush(stdout)
        }
        while true {
            print("\u{1B}[2J\u{1B}[H" + picker.lines(home: home).joined(separator: "\n"))
            fflush(stdout)
            var buffer = [UInt8](repeating: 0, count: 8)
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            guard count > 0 else { return .cancel }
            guard let key = InstallPicker.key(for: Array(buffer.prefix(count))) else { continue }
            if let outcome = picker.handle(key) {
                print("\u{1B}[2J\u{1B}[H", terminator: "")
                return outcome
            }
        }
    }
}
