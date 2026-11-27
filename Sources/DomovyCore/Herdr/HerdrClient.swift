import Foundation

/// Talks to a running Herdr server through its documented CLI (`herdr workspace list`,
/// `pane list`, `agent list`, `pane process-info`), each with a short timeout. Never reads a
/// pane's screen. Without a server (no socket) nothing runs at all, so no server is started.
public struct HerdrClient: Sendable {
    public let executable: URL?
    /// The socket a running server listens on: `~/.config/herdr/herdr.sock`.
    public let socket: URL
    public let timeout: TimeInterval

    public init(executable: URL?, socket: URL, timeout: TimeInterval = 3) {
        self.executable = executable
        self.socket = socket
        self.timeout = timeout
    }

    /// The client for a home folder. A custom home (fixture or `.devhome`) only gets a stub at
    /// `<home>/bin/herdr`; `DOMOVY_HERDR_CLI` overrides, empty turns Herdr off.
    public static func at(home: URL, isCustomHome: Bool, environment: [String: String] = ProcessInfo.processInfo.environment) -> HerdrClient {
        let choice = ToolChoice.at(home: home, isCustomHome: isCustomHome, name: "herdr", override: "DOMOVY_HERDR_CLI", environment: environment)
        let config = environment["HERDR_CONFIG_PATH"].map { URL(fileURLWithPath: $0).deletingLastPathComponent() }
        let folder = (isCustomHome ? nil : config) ?? home.appendingPathComponent(".config/herdr", isDirectory: true)
        return HerdrClient(executable: choice.resolve("herdr"), socket: folder.appendingPathComponent("herdr.sock"))
    }

    /// The CLI is installed and a server socket exists. Cheap: no process runs.
    public var mayBeRunning: Bool {
        executable != nil && FileManager.default.fileExists(atPath: socket.path)
    }

    /// Workspaces, panes and agents, or `nil` when no server answers.
    public func state() -> HerdrState? {
        guard mayBeRunning, let workspaces = json(["workspace", "list"]) else { return nil }
        return HerdrState.parse(workspaces: workspaces, panes: json(["pane", "list"]) ?? Data(), agents: json(["agent", "list"]) ?? Data())
    }

    /// The pid of the shell Herdr started for `pane`.
    public func shellPID(ofPane pane: String) -> Int32? {
        json(["pane", "process-info", "--pane", pane]).flatMap(HerdrState.shellPID(fromProcessInfo:))
    }

    /// Runs one command and returns its JSON output, `nil` on failure (server errors exit 1).
    public func json(_ arguments: [String], timeout: TimeInterval? = nil) -> Data? {
        guard let executable, let result = ExternalTool.output(executable, arguments, timeout: timeout ?? self.timeout),
              result.status == 0 else { return nil }
        return Data(result.stdout.utf8)
    }
}
