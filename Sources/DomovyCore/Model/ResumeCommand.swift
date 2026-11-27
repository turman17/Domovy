import Foundation

/// The agent's own command that reopens a session, run in its project folder. Domovy only
/// builds it; the app hands it to a terminal, and the agent does the rest.
public struct ResumeCommand: Hashable, Sendable {
    public let agent: AgentKind
    public let executable: String
    public let arguments: [String]
    /// The folder to run it in; `nil` when the agent finds the session from anywhere.
    public let directory: String?

    /// Why a session cannot be resumed from Domovy, in words for a disabled button's help.
    public enum Unavailable: Error, Hashable, Sendable, LocalizedError {
        case noCommand(AgentKind)
        case editorChat(AgentKind)
        case noProject(AgentKind)
        case projectMissing(String)
        case unsafeID(AgentKind)
        case live(AgentKind)

        public var errorDescription: String? {
            switch self {
            case .noCommand(let agent): "\(agent.displayName) has no command to resume a session from a terminal."
            case .editorChat(let agent): "This chat lives in \(agent.displayName)'s editor; open it there."
            case .noProject(let agent): "\(agent.displayName) resumes a session from its project folder, and this session has none recorded."
            case .projectMissing(let path): "The project folder \((path as NSString).abbreviatingWithTildeInPath) is gone, so the agent cannot resume there."
            case .unsafeID(let agent): "This \(agent.displayName) session's id has characters Domovy does not put into a command."
            case .live(let agent): "This session is open in \(agent.displayName) already."
            }
        }
    }

    /// The command for `session`, or why there is none. `folderExists` is injected for tests.
    public static func resolve(for session: Session,
                               folderExists: (String) -> Bool = { path in
                                   var isDirectory: ObjCBool = false
                                   return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
                               }) -> Result<ResumeCommand, Unavailable> {
        let agent = session.agent
        // Each from the agent's documentation: `claude --resume`, `codex resume`,
        // `gemini --resume`, `qwen --resume`, `opencode --session`, `copilot --resume`,
        // `cursor-agent --resume`, and Aider's `--restore-chat-history`.
        let spec: (executable: String, arguments: [String], needsProject: Bool)
        switch agent {
        case .claudeCode: spec = ("claude", ["--resume", session.id], true)
        case .codex: spec = ("codex", ["resume", session.id], false)
        case .gemini: spec = ("gemini", ["--resume", session.id], true)
        case .qwen: spec = ("qwen", ["--resume", session.id], true)
        case .openCode: spec = ("opencode", ["--session", session.id], false)
        case .copilot: spec = ("copilot", ["--resume", session.id], false)
        case .cursor:
            if CursorAdapter.isEditorChat(session) { return .failure(.editorChat(agent)) }
            spec = ("cursor-agent", ["--resume", session.id], true)
        case .aider: spec = ("aider", ["--restore-chat-history"], true)
        default: return .failure(.noCommand(agent))
        }
        if agent != .aider, !SafeID.isSafe(session.id) { return .failure(.unsafeID(agent)) }
        if session.status == .live { return .failure(.live(agent)) }
        var directory: String?
        if let project = session.projectPath, project.hasPrefix("/") {
            guard folderExists(project) else {
                if spec.needsProject { return .failure(.projectMissing(project)) }
                return .success(ResumeCommand(agent: agent, executable: spec.executable, arguments: spec.arguments, directory: nil))
            }
            directory = project
        } else if spec.needsProject {
            return .failure(.noProject(agent))
        }
        return .success(ResumeCommand(agent: agent, executable: spec.executable, arguments: spec.arguments, directory: directory))
    }

    /// `cd '/path' && claude --resume <id>`, for copying.
    public var shellLine: String {
        let command = ([executable] + arguments).map(Self.quoted).joined(separator: " ")
        return directory.map { "cd \(Self.quoted($0)) && " + command } ?? command
    }

    /// A `.command` file's text: removes itself, then runs the command in the project folder.
    /// The terminal keeps the window open afterwards.
    public var script: String {
        var lines = ["#!/bin/zsh", "# Written by Domovy to resume a \(agent.displayName) session.", "rm -f -- \"$0\""]
        if let directory { lines.append("cd -- \(Self.quoted(directory)) || exit 1") }
        lines.append(([executable] + arguments).map(Self.quoted).joined(separator: " "))
        return lines.joined(separator: "\n") + "\n"
    }

    /// Single-quoted for the shell unless it is plainly safe.
    static func quoted(_ text: String) -> String {
        let plain = !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./=@:".contains($0)) }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
