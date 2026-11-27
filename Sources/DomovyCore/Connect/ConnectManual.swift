import Foundation

/// A connect or disconnect step written out for a person to do by hand: a shell command to
/// paste into Terminal, or the exact text to put in a config file.
public struct ManualStep: Sendable, Hashable {
    /// One line: "Run in Terminal", "Add to ~/.cursor/mcp.json".
    public let title: String
    /// The command or file text, ready to copy.
    public let text: String
    public let isShellCommand: Bool
}

extension ConnectStep {
    /// This step as something a person can run or paste. `domo` is the executable the plan
    /// registers; the skill commands print the same files Domovy would write.
    public func manual(home: URL, domo: String?) -> ManualStep {
        let path = { (url: URL) in ConnectManual.shellPath(url, home: home) }
        switch self {
        case .runCommand(let command):
            let line = ([command.executable.lastPathComponent] + command.arguments).map(ConnectManual.quoted).joined(separator: " ")
            return ManualStep(title: command.note, text: line, isShellCommand: true)
        case .writeConfig(let file, _, _, _, let snippet):
            let verb = snippet.hasPrefix("Delete") ? "Edit" : "Add to"
            return ManualStep(title: "\(verb) \(DomovyTools.display(file, home: home))", text: snippet, isShellCommand: false)
        case .installSkill(let directory, _, _):
            let domo = domo.map(ConnectManual.quoted) ?? "domo"
            return ManualStep(title: "Install the domovy skill",
                              text: "mkdir -p \(path(directory)) && \(domo) connect --print-skill > \(path(directory.appendingPathComponent("SKILL.md")))"
                                  + " && \(domo) connect --print-skill-references > \(path(directory.appendingPathComponent("references.md")))",
                              isShellCommand: true)
        case .removeSkill(let directory):
            return ManualStep(title: "Move the domovy skill to the Trash", text: "mv \(path(directory)) ~/.Trash/domovy-skill-$(date +%s)", isShellCommand: true)
        case .removeFile(let file):
            return ManualStep(title: "Move \(file.lastPathComponent) to the Trash", text: "mv \(path(file)) ~/.Trash/", isShellCommand: true)
        }
    }
}

extension AgentConnectPlan {
    /// Every step of this agent by hand.
    public func manualSteps(home: URL, domo: String?) -> [ManualStep] {
        steps.map { $0.manual(home: home, domo: domo) }
    }
}

extension ConnectPlan {
    /// One script for Terminal covering the chosen agents: commands as they are, file changes
    /// as comments to apply by hand.
    public func manualScript(home: URL, agents: Set<ConnectAgent>? = nil) -> String {
        let domo = command.first
        var lines: [String] = []
        for item in self.agents where item.state == .willChange && (agents?.contains(item.agent) ?? true) {
            lines.append("# \(item.agent.displayName)")
            for step in item.manualSteps(home: home, domo: domo) {
                if step.isShellCommand {
                    lines.append(step.text)
                } else {
                    lines.append("# \(step.title):")
                    lines += step.text.split(separator: "\n", omittingEmptySubsequences: false).map { "#   \($0)" }
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}

enum ConnectManual {
    /// Single-quoted for the shell unless it is plainly safe.
    static func quoted(_ text: String) -> String {
        let plain = !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_./=@:+,".contains($0)) }
        return plain ? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A path for the shell, `~/…` under the home folder so the command reads like the user's own.
    static func shellPath(_ url: URL, home: URL) -> String {
        let path = url.standardizedFileURL.path
        let base = home.standardizedFileURL.path
        guard path.hasPrefix(base + "/"), base == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path else { return quoted(path) }
        return "~/" + quoted(String(path.dropFirst(base.count + 1)))
    }
}

extension AgentConnector {
    /// The server entry as a small config file of its own, the way a person would paste it in.
    static func snippet(_ agent: ConnectAgent, command: [String], data: Data?) -> String {
        let name = MCPRegistration.serverName
        if agent.isTOML {
            return "[mcp_servers.\(name)]\ncommand = \(TOMLTableEditor.quote(command[0]))\nargs = [\(command.dropFirst().map(TOMLTableEditor.quote).joined(separator: ", "))]"
        }
        let path = agent.serverPath(in: data)
        let siblings = (data.flatMap { try? JSONCEditor.memberValues(at: path, in: $0) }) ?? [:]
        let value = agent.entry(command: command, path: path, siblings: siblings)
        let rendered = (try? JSONCEditor.inserting(name, value: value, at: path, in: Data("{}".utf8)))?.data
        return rendered.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
