import ArgumentParser
import DomovyCore
import Foundation

@main
struct Domo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "domo",
        abstract: "Domovy: tidy up after AI coding agents.",
        discussion: "With no command and stdin not a terminal (an agent starting it), runs the MCP server, like `domo mcp`.",
        version: DomovyVersion.current,
        subcommands: [Ls.self, Search.self, Du.self, Rm.self, Archive.self, Orphans.self, Clean.self, Leftovers.self, Models.self, Secrets.self, Redact.self, Purge.self, Undo.self, Ps.self, Freeze.self, Resume.self, Quit.self, Mcp.self, Install.self, Update.self, Connect.self, Disconnect.self, Rules.self]
    )

    /// `domo` alone: the MCP server when stdin is piped (how agents start it), else the help.
    func run() async throws {
        guard isatty(STDIN_FILENO) == 0 else {
            print(Self.helpMessage())
            return
        }
        await Mcp.serve(DomovyContext.fromEnvironment())
    }

    static func printLeftovers(_ entries: [UndoEntry]) {
        for note in entries.flatMap(\.notes) { print("\n\(note)") }
        let leftovers = entries.flatMap(\.leftovers)
        guard !leftovers.isEmpty else { return }
        print("\nChecked afterwards; left behind:")
        for item in leftovers { print("  - \(item)") }
    }
}

/// Options every subcommand shares. `--root` is a home directory; adapters look inside it
/// (`<root>/.claude`, ...). Domovy's own quarantine and undo log live under
/// `<root>/Library/Application Support/Domovy`, so a fixture home stays self-contained.
struct RootOptions: ParsableArguments {
    @Option(name: .long, help: "Home directory to scan. Defaults to your home. Use a fixture copy when testing.", completion: .directory)
    var root: String?

    var home: URL {
        if let root { return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    var claudeCode: ClaudeCodeAdapter {
        ClaudeCodeAdapter(home: home)
    }

    /// Adapters and executor for this home. A `--root` home never gets the real codex or opencode CLI.
    var context: DomovyContext {
        DomovyContext(home: home, isCustomHome: root != nil)
    }

    /// Every adapter, in display order.
    var adapters: [any AgentAdapter] {
        context.adapters
    }

    /// Every installed agent's sessions, each agent listed once (Aider reuses the others'
    /// project folders instead of listing them again).
    func scan() async -> [AgentSessionScan] {
        await context.scanSessions()
    }

    /// The one session across all agents with this id or unique id prefix.
    func session(matching idOrPrefix: String) async throws -> (adapter: any AgentAdapter, session: Session) {
        try Self.session(matching: idOrPrefix, in: await scan())
    }

    static func session(matching idOrPrefix: String, in scans: [AgentSessionScan]) throws -> (adapter: any AgentAdapter, session: Session) {
        var matches: [(adapter: any AgentAdapter, session: Session)] = []
        for scan in scans {
            if let error = scan.error { throw error }
            // OpenCode ids are mixed case; the others are lowercase.
            for session in scan.sessions where session.id.lowercased().hasPrefix(idOrPrefix.lowercased()) {
                if session.id.lowercased() == idOrPrefix.lowercased() { return (scan.adapter, session) }
                matches.append((scan.adapter, session))
            }
        }
        guard matches.count == 1, let match = matches.first else { throw AdapterError.sessionNotFound(idOrPrefix) }
        return match
    }

    /// Ollama, LM Studio and Hugging Face. A `--root` home ignores `OLLAMA_MODELS` and friends.
    var modelStores: ModelStores {
        ModelStores.at(home: home, isCustomHome: root != nil)
    }

    /// Every disk footprint: the adapters, the measured-only agents and the model stores,
    /// without the agents hidden in Settings.
    var footprintProviders: [any FootprintProvider] {
        context.footprintProviders
    }

    /// `settings.json` in Domovy's folder under this home (the app's Settings window writes it).
    var settings: DomovySettings {
        SettingsStore.settings(storeRoot: DomovyContext.storeRoot(home: home))
    }

    /// `--to` when given, else the default destination from Settings.
    func destination(_ to: Destination?) -> Destination {
        settings.destination(to)
    }

    /// Guided cleanups and model removals. A `--root` home runs only stub CLIs from `<root>/bin`.
    var cleanupPlanner: CleanupPlanner {
        CleanupPlanner(home: home, isCustomHome: root != nil)
    }

    var executor: Executor {
        Executor(storeRoot: home.appendingPathComponent("Library/Application Support/Domovy", isDirectory: true))
    }
}

extension Domo {
    /// Prints to stderr and exits with a user-explainable message.
    static func fail(_ error: Error) -> ExitCode {
        FileHandle.standardError.write(Data("domo: \(error.localizedDescription)\n".utf8))
        return .failure
    }
}

/// Asks on a terminal; without one the user must pass --yes so scripts never change files by accident.
func confirm(_ prompt: String) throws {
    guard isatty(STDIN_FILENO) != 0 else { throw DomoError.confirmationRequired }
    print(prompt, terminator: "")
    guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(),
          answer == "y" || answer == "yes" else {
        throw DomoError.cancelled
    }
}
