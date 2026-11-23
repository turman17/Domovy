import Foundation

/// The `ollama` CLI. It talks to the Ollama server over HTTP; with the server down, `ollama rm`
/// and `ollama ps` fail (verified on 0.33.3), and Domovy falls back to moving files itself.
struct OllamaCLI: Sendable {
    let executable: URL

    /// The app bundle ships the CLI inside it; Homebrew puts it in `/opt/homebrew/bin`.
    static let extraLocations = ["/Applications/Ollama.app/Contents/Resources"]

    static func resolve(_ choice: ToolChoice) -> OllamaCLI? {
        choice.resolve("ollama", extra: extraLocations).map(OllamaCLI.init)
    }

    /// Model names `ollama ps` lists as loaded, or `nil` when the server does not answer.
    /// Read-only: `ollama ps` only asks the server what it has in memory.
    func loadedModels(storeEnvironment: [String: String]) -> [String]? {
        guard let result = ExternalTool.output(executable, ["ps"], environment: storeEnvironment), result.status == 0 else { return nil }
        return Self.parsePS(result.stdout)
    }

    /// `NAME  ID  SIZE  PROCESSOR  UNTIL` (or `CONTEXT` on newer versions): the first column of
    /// every row after the header.
    static func parsePS(_ output: String) -> [String] {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let header = lines.first, header.hasPrefix("NAME") else { return [] }
        return lines.dropFirst().compactMap { $0.split(separator: " ").first.map(String.init) }
    }
}

/// The `hf` CLI (huggingface_hub 1.x). Used only when `hf cache --help` lists both `rm` and
/// `prune`; argument forms come from the hub docs and are not verified on an install yet.
struct HuggingFaceCLI: Sendable {
    let executable: URL

    static func resolve(_ choice: ToolChoice, hub: URL) -> HuggingFaceCLI? {
        guard let url = choice.resolve("hf"),
              let help = ExternalTool.output(url, ["cache", "--help"], environment: environment(hub)), help.status == 0 else { return nil }
        // Typer renders commands in a box ("│ rm  ..."), so look for the words, not the layout.
        let words = Set(help.stdout.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "│|"))))
        guard words.contains("rm"), words.contains("prune") else {
            Log.adapter.info("hf cache --help lists no rm or prune; using the file fallback")
            return nil
        }
        return HuggingFaceCLI(executable: url)
    }

    /// Points the CLI at the cache Domovy scanned.
    static func environment(_ hub: URL) -> [String: String] {
        ["HF_HUB_CACHE": hub.path]
    }
}

/// Ollama's naming rules, for the CLI and tests.
public enum OllamaNames {
    /// `qwen3` and `library/qwen3:latest` both mean `qwen3:latest`.
    public static func canonical(_ name: String) -> String { OllamaStore.canonical(name) }
    /// Model names in `ollama ps` output.
    public static func parsePS(_ output: String) -> [String] { OllamaCLI.parsePS(output) }
}
