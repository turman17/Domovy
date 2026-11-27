import Foundation

/// OpenCode and its forks that keep the same database: the agent, its data folder name, its
/// database file and its CLI. Kilo Code is an OpenCode fork with the same `session`, `message`
/// and `part` tables in `~/.local/share/kilo/kilo.db` (Kilo-Org/kilocode@bfdec549,
/// packages/core/src/session/sql.ts#L24-L114, packages/core/src/database/database.ts#L50-L67;
/// docs/research/agent_storage_formats.md, Q9; not verified on a real install).
public struct OpenCodeFlavor: Sendable, Hashable {
    public let kind: AgentKind
    /// The folder under `~/.local/share` and `~/.config`.
    public let folder: String
    public let databaseName: String
    /// The CLI's executable name, also the process name.
    public let executable: String
    /// The npm package the CLI runs from under node.
    public let npmMarker: String
    /// Where the curl installer puts the binary, relative to home.
    public let installedBin: String
    /// Environment variable that names the CLI to run, empty to disable.
    public let cliOverride: String
    /// Files besides the database the agent needs (sign-ins), never planned.
    public let protectedFiles: Set<String>

    public static let openCode = OpenCodeFlavor(
        kind: .openCode, folder: "opencode", databaseName: "opencode.db", executable: "opencode", npmMarker: "opencode-ai",
        installedBin: ".opencode/bin", cliOverride: "DOMOVY_OPENCODE_CLI", protectedFiles: ["auth.json", "mcp-auth.json", "bin"])

    /// `kilo` is a Node launcher (`@kilocode/cli`, bin/kilo) that starts a compiled `kilo`
    /// binary (packages/opencode/package.json, script/build.ts#L339-L347). `auth.json` lives in
    /// the data folder (packages/core/src/credential.ts#L165).
    public static let kilo = OpenCodeFlavor(
        kind: .kilo, folder: "kilo", databaseName: "kilo.db", executable: "kilo", npmMarker: "@kilocode/cli",
        installedBin: ".kilo/bin", cliOverride: "DOMOVY_KILO_CLI", protectedFiles: ["auth.json", "mcp-auth.json", "bin"])

    var appName: String { kind.displayName }

    /// The data folder as the CLI finds it. OpenCode and Kilo both use the XDG base directories
    /// (`xdg-basedir`); Kilo also takes `KILO_DB` (absolute path wins, database.ts#L50-L67), which
    /// pins the database even on a dev channel that would pick `kilo-<channel>.db`.
    func environment(dataFolder: URL) -> [String: String] {
        var environment = ["XDG_DATA_HOME": dataFolder.deletingLastPathComponent().path]
        if kind == .kilo { environment["KILO_DB"] = dataFolder.appendingPathComponent(databaseName).path }
        return environment
    }
}
