import Foundation

/// launchd's user environment, read with `launchctl getenv` (read-only). Apps started from the
/// Dock or at login, like the Ollama app and its server, inherit it instead of the shell's.
public enum LaunchdEnvironment {
    static let launchctl = URL(fileURLWithPath: "/bin/launchctl")

    /// The value, or `nil` when it is unset, empty or `launchctl` could not run.
    @Sendable public static func value(_ name: String) -> String? {
        guard let result = ExternalTool.output(launchctl, ["getenv", name], timeout: 3), result.status == 0 else { return nil }
        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// The reader for a home: a custom home (a fixture, `.devhome`) never reads launchd.
    public static func reader(isCustomHome: Bool) -> @Sendable (String) -> String? {
        if isCustomHome { return { _ in nil } }
        return { value($0) }
    }
}
