import Foundation

/// Resuming a session in Herdr instead of a terminal window: a new tab in the workspace that
/// already works in the project folder (else a new workspace there), then
/// `herdr agent start <name> --kind <kind> --pane <id> -- <resume args>`. Only built here;
/// the app runs the two commands when the user asks.
public struct HerdrResume: Hashable, Sendable {
    /// Herdr's agent kind (`claude`, `codex`).
    public let kind: String
    /// A new, unique live agent name.
    public let name: String
    public let directory: String
    /// The agent's own resume arguments, without the executable (`--resume <id>`).
    public let arguments: [String]
    /// The workspace that gets the new tab; `nil` makes a new workspace.
    public let workspaceID: String?

    /// `herdr tab create …` or `herdr workspace create …`; the response's `root_pane` is the pane.
    public var paneArguments: [String] {
        if let workspaceID {
            return ["tab", "create", "--workspace", workspaceID, "--cwd", directory, "--label", name, "--focus"]
        }
        return ["workspace", "create", "--cwd", directory, "--label", Self.folderLabel(directory), "--focus"]
    }

    /// `herdr agent start …` for the pane the first command made.
    public func startArguments(pane: String) -> [String] {
        ["agent", "start", name, "--kind", kind, "--pane", pane, "--"] + arguments
    }

    /// The plan for `command`, or `nil` when Herdr cannot start this agent (then the terminal does).
    public static func plan(for command: ResumeCommand, sessionID: String, in state: HerdrState,
                            home: String = NSHomeDirectory()) -> HerdrResume? {
        guard let kind = HerdrAgentKind.kind(for: command.agent) else { return nil }
        let directory = command.directory ?? home
        return HerdrResume(kind: kind, name: uniqueName(for: sessionID, taken: Set(state.agents.compactMap(\.name))),
                           directory: directory, arguments: command.arguments,
                           workspaceID: state.workspace(forFolder: directory)?.id)
    }

    /// `herdr agent focus <pane>`: shows the pane where a live session runs.
    public static func focusArguments(pane: String) -> [String] { ["agent", "focus", pane] }

    /// `resume-1fb61a59`, made unique against live names. Herdr allows `[a-z][a-z0-9_-]{0,31}`.
    static func uniqueName(for sessionID: String, taken: Set<String>) -> String {
        let stem = "resume-" + String(sessionID.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        var name = stem
        var counter = 2
        while taken.contains(name) {
            name = "\(stem)-\(counter)"
            counter += 1
        }
        return String(name.prefix(32))
    }

    /// The folder's name, for a new workspace's sidebar label.
    static func folderLabel(_ directory: String) -> String {
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? "~" : name
    }
}
