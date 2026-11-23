import ArgumentParser
import DomovyCore
import Foundation

@main
struct Domo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "domo",
        abstract: "Domovy: tidy up after AI coding agents.",
        subcommands: [Ls.self, Du.self, Rm.self, Archive.self, Orphans.self, Clean.self, Models.self, Secrets.self, Redact.self, Purge.self, Undo.self]
    )

    static func printLeftovers(_ entries: [UndoEntry]) {
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

    /// Every adapter, in display order. A `--root` home never gets the real codex CLI.
    var adapters: [any AgentAdapter] {
        [claudeCode, CodexAdapter(home: home, cli: CodexCLI.choice(home: home, isCustomHome: root != nil))]
    }

    /// Adapters whose agent is present at this root.
    func installedAdapters() async -> [any AgentAdapter] {
        var result: [any AgentAdapter] = []
        for adapter in adapters where await adapter.status() != .notInstalled { result.append(adapter) }
        return result
    }

    /// The one session across all agents with this id or unique id prefix.
    func session(matching idOrPrefix: String) async throws -> (adapter: any AgentAdapter, session: Session) {
        var matches: [(adapter: any AgentAdapter, session: Session)] = []
        for adapter in await installedAdapters() {
            for session in try await adapter.sessions() where session.id.hasPrefix(idOrPrefix.lowercased()) {
                if session.id == idOrPrefix.lowercased() { return (adapter, session) }
                matches.append((adapter, session))
            }
        }
        guard matches.count == 1, let match = matches.first else { throw AdapterError.sessionNotFound(idOrPrefix) }
        return match
    }

    /// Ollama, LM Studio and Hugging Face. A `--root` home ignores `OLLAMA_MODELS` and friends.
    var modelStores: ModelStores {
        ModelStores.at(home: home, isCustomHome: root != nil)
    }

    /// Every disk footprint: the adapters, the measured-only agents and the model stores.
    var footprintProviders: [any FootprintProvider] {
        adapters + FootprintScanner.measuredOnly(home: home) + FootprintScanner.modelStores(modelStores)
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
