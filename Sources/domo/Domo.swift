import ArgumentParser
import DomovyCore
import Foundation

@main
struct Domo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "domo",
        abstract: "Domovy: tidy up after AI coding agents.",
        subcommands: [Ls.self, Du.self, Rm.self, Archive.self, Undo.self]
    )
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

    var adapter: ClaudeCodeAdapter {
        ClaudeCodeAdapter(home: home)
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
