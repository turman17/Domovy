import Foundation
import os

/// One change `domo connect` or `disconnect` makes for an agent.
public enum ConnectStep: Sendable, Hashable {
    /// Replace a config file's bytes (`before` is `nil` for a new file). Checked unchanged
    /// right before writing; the old file is backed up first.
    /// `snippet` is the same change for a person to make by hand (`ConnectStep.manual`).
    case writeConfig(file: URL, before: Data?, after: Data, note: String, snippet: String)
    /// Run the agent's own command, then check its config says what we expect.
    case runCommand(PlannedCommand)
    /// Writes the skill folder's files (`DomovySkill.files`), by name.
    case installSkill(directory: URL, files: [String: String], replacing: Bool)
    /// Moves Domovy's own skill folder to Domovy's store (never a permanent delete).
    case removeSkill(directory: URL)
    /// Moves a config file connect created, now empty again, to Domovy's store.
    case removeFile(URL)

    public func description(home: URL) -> String {
        let show = { (url: URL) in DomovyTools.display(url, home: home) }
        switch self {
        case .writeConfig(let file, let before, _, let note, _): return "\(note) in \(show(file))" + (before == nil ? " (new file)" : "")
        case .runCommand(let command): return "Run `\(([command.executable.lastPathComponent] + command.arguments).joined(separator: " "))`"
        case .installSkill(let directory, _, let replacing): return "\(replacing ? "Update" : "Install") the domovy skill: \(show(directory.appendingPathComponent("SKILL.md")))"
        case .removeSkill(let directory): return "Remove the domovy skill: \(show(directory))"
        case .removeFile(let url): return "Remove \(show(url)), which Domovy created and is empty again"
        }
    }
}

/// What connect or disconnect does for one agent.
public struct AgentConnectPlan: Sendable, Identifiable {
    public enum State: Sendable, Hashable {
        case willChange
        case upToDate
        case notDetected
        case refused(String)
    }

    public var id: ConnectAgent { agent }
    public let agent: ConnectAgent
    public let state: State
    public let steps: [ConnectStep]
    /// Facts the user should know: a skill Domovy did not overwrite, how to reload.
    public let notes: [String]
    /// Whether the agent has Domovy's server registered now.
    public let isConnected: Bool
    let record: ConnectRecord.Entry?
}

public struct ConnectPlan: Sendable {
    public enum Mode: String, Sendable { case connect, disconnect }
    public let mode: Mode
    public let command: [String]
    public let agents: [AgentConnectPlan]

    public var hasChanges: Bool { agents.contains { $0.state == .willChange } }
}

/// The result for one agent after executing.
public struct AgentConnectResult: Sendable, Identifiable {
    public enum Outcome: Sendable, Hashable {
        case changed
        case unchanged
        case failed(String)
    }

    public var id: ConnectAgent { agent }
    public let agent: ConnectAgent
    public let outcome: Outcome
    public let notes: [String]
}

/// What connect did, so disconnect removes exactly that. Kept in Domovy's store.
struct ConnectRecord: Codable, Sendable {
    struct Entry: Codable, Sendable, Hashable {
        var configFile: String
        var createdFile: Bool
        var insertion: JSONCEditor.Insertion?
        var appendedTOML: String?
    }

    var agents: [String: Entry] = [:]
    /// Folders connect created for a skill or a new config file (`~/.kimi/skills`,
    /// `~/.continue/mcpServers`), outermost; disconnect removes them again once empty.
    var createdFolders: [String]? = nil
}

/// Registers Domovy's MCP server and skill with agents, and removes them again. Everything
/// is planned first (`plan`), shown, then executed (`execute`), like Domovy's other actions.
public struct AgentConnector: Sendable {
    public let home: URL
    public let isCustomHome: Bool
    public let storeRoot: URL
    let processes: any RunningProcessLister
    /// Refuse edits of files an app rewrites while it runs. Off for a custom home by default:
    /// apps running on this Mac do not use a fixture's files.
    let checksRunningApps: Bool
    let runner: any CommandRunner
    /// The agent's CLI, if Domovy may run it. A custom home never runs the real CLIs.
    let locateCLI: @Sendable (String) -> URL?
    let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "com.turman.domovy", category: "connect")

    public init(
        home: URL,
        isCustomHome: Bool,
        storeRoot: URL? = nil,
        processes: any RunningProcessLister = LibprocProcessLister(),
        checksRunningApps: Bool? = nil,
        runner: any CommandRunner = ProcessCommandRunner(timeout: 60),
        locateCLI: (@Sendable (String) -> URL?)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.home = home.standardizedFileURL
        self.isCustomHome = isCustomHome
        self.storeRoot = (storeRoot ?? DomovyContext.storeRoot(home: home)).standardizedFileURL
        self.processes = processes
        self.checksRunningApps = checksRunningApps ?? !isCustomHome
        self.runner = runner
        let home = home
        self.locateCLI = locateCLI ?? { name in
            isCustomHome ? nil : ExternalTool.locate(name, extra: [home.appendingPathComponent(".claude/local").path, home.appendingPathComponent(".opencode/bin").path])
        }
        self.now = now
    }

    var recordFile: URL { storeRoot.appendingPathComponent("Connect/connections.json") }

    /// Agents found at this home.
    public func detected() -> [ConnectAgent] {
        ConnectAgent.allCases.filter { agent in agent.markers.contains { FileManager.default.fileExists(atPath: home.appendingPathComponent($0).path) } }
    }

    // MARK: Plan

    /// Detected agents that have Domovy's server registered now, by any command (a skills
    /// folder alone may be shared with another agent). `domo install --refresh` updates these.
    public func connected() -> [ConnectAgent] {
        detected().filter { agent in
            guard let data = try? Data(contentsOf: agent.configFile(home: home)) else { return false }
            return (try? registered(agent, in: data)) != nil
        }
    }

    /// Re-registers the agents that have Domovy with `command` and rewrites their skill, e.g.
    /// after an upgrade moved `domo`. Agents without Domovy stay as they are.
    public func refreshPlan(command: [String]) -> ConnectPlan {
        plan(.connect, command: command, agents: connected())
    }

    /// - Parameter agents: the agents to change; `nil` means every detected one.
    public func plan(_ mode: ConnectPlan.Mode, command: [String], agents: [ConnectAgent]? = nil) -> ConnectPlan {
        let found = Set(detected())
        let chosen = agents ?? ConnectAgent.allCases.filter { found.contains($0) }
        let record = readRecord()
        let plans = chosen.map { agent -> AgentConnectPlan in
            guard found.contains(agent) else {
                return AgentConnectPlan(agent: agent, state: .notDetected, steps: [], notes: ["\(agent.displayName) was not found here."], isConnected: false, record: nil)
            }
            // The app plans before it knows where `domo` is; an entry needs its path.
            if mode == .connect, command.isEmpty {
                return AgentConnectPlan(agent: agent, state: .refused(Self.missingCommand), steps: [], notes: [], isConnected: false, record: nil)
            }
            do {
                return mode == .connect
                    ? try planConnect(agent, command: command, record: record)
                    : try planDisconnect(agent, record: record, leaving: Set(chosen), detected: found)
            } catch {
                return AgentConnectPlan(agent: agent, state: .refused(Self.explain(error, agent: agent)), steps: [], notes: [], isConnected: false, record: nil)
            }
        }
        return ConnectPlan(mode: mode, command: command, agents: plans)
    }

    private func planConnect(_ agent: ConnectAgent, command: [String], record: ConnectRecord) throws -> AgentConnectPlan {
        let file = agent.configFile(home: home)
        let before = try? Data(contentsOf: file)
        var steps: [ConnectStep] = []
        var notes: [String] = []
        var entry: ConnectRecord.Entry?
        let current = try registered(agent, in: before)
        if current != command {
            if let cli = agent.cli, let executable = locateCLI(cli.name) {
                if current != nil { steps.append(.runCommand(PlannedCommand(executable: executable, arguments: cli.remove, note: "Remove the old domovy entry"))) }
                steps.append(.runCommand(PlannedCommand(executable: executable, arguments: cli.add + command, note: "Add domovy")))
                entry = ConnectRecord.Entry(configFile: file.path, createdFile: false)
            } else {
                if let matcher = agent.rewritesConfigWhileRunning, checksRunningApps {
                    let blocking = processes.blockingReasons([matcher])
                    guard blocking.isEmpty else { throw ConnectError.appRunning(blocking.joined(separator: " ")) }
                }
                let previous = record.agents[agent.rawValue]
                let (after, recorded) = try edited(agent, data: before ?? Data(), command: command, replacing: current != nil, previous: previous)
                entry = recorded.map { recorded in
                    var entry = recorded
                    entry.createdFile = current == nil ? before == nil : previous?.createdFile ?? false
                    return entry
                } ?? previous
                steps.append(.writeConfig(file: file, before: before, after: after,
                                          note: current == nil ? "Add \"domovy\" to \(Self.keyText(agent, before))" : "Update \"domovy\" in \(Self.keyText(agent, before))",
                                          snippet: Self.snippet(agent, command: command, data: before)))
            }
        }
        if let directory = agent.skillsDirectory(home: home)?.appendingPathComponent(DomovySkill.name, isDirectory: true) {
            let files = DomovySkill.files(command: command)
            switch Self.skillState(at: directory, expected: files) {
            case .absent: steps.append(.installSkill(directory: directory, files: files, replacing: false))
            case .current: break
            // An older version, or one naming another domo path: rewrite it.
            case .outdated: steps.append(.installSkill(directory: directory, files: files, replacing: true))
            case .foreign: notes.append("A different skill named domovy is in \(DomovyTools.display(directory, home: home)); Domovy left it alone.")
            }
        } else {
            notes.append("\(agent.displayName) has no skills folder; the MCP server's own instructions explain the tools.")
        }
        if !steps.isEmpty { notes.append(agent.reloadAdvice) }
        return AgentConnectPlan(agent: agent, state: steps.isEmpty ? .upToDate : .willChange, steps: steps, notes: notes,
                                isConnected: current == command, record: entry)
    }

    private func planDisconnect(_ agent: ConnectAgent, record: ConnectRecord, leaving: Set<ConnectAgent>, detected: Set<ConnectAgent>) throws -> AgentConnectPlan {
        let file = agent.configFile(home: home)
        let before = try? Data(contentsOf: file)
        var steps: [ConnectStep] = []
        let current = try registered(agent, in: before)
        let recorded = record.agents[agent.rawValue]
        if current != nil, let before {
            if let cli = agent.cli, let executable = locateCLI(cli.name) {
                steps.append(.runCommand(PlannedCommand(executable: executable, arguments: cli.remove, note: "Remove domovy")))
            } else {
                if let matcher = agent.rewritesConfigWhileRunning, checksRunningApps {
                    let blocking = processes.blockingReasons([matcher])
                    guard blocking.isEmpty else { throw ConnectError.appRunning(blocking.joined(separator: " ")) }
                }
                let after = try removed(agent, data: before, record: recorded)
                let empty = String(decoding: JSONCEditor.strip([UInt8](after)), as: UTF8.self).filter { !$0.isWhitespace }
                if recorded?.createdFile == true, empty == "{}" || empty.isEmpty {
                    steps.append(.removeFile(file))
                } else {
                    steps.append(.writeConfig(file: file, before: before, after: after, note: "Remove \"domovy\" from \(Self.keyText(agent, before))",
                                              snippet: "Delete the \"domovy\" entry under \(Self.keyText(agent, before)); leave everything else as it is."))
                }
            }
        }
        if let skills = agent.skillsDirectory(home: home) {
            let directory = skills.appendingPathComponent(DomovySkill.name, isDirectory: true)
            // A shared skills folder keeps the skill while another connected agent still reads it.
            let others = detected.subtracting(leaving).filter { other in
                other.skillsDirectory(home: home)?.standardizedFileURL == skills.standardizedFileURL
                    && (try? registered(other, in: try? Data(contentsOf: other.configFile(home: home)))) != nil
            }
            let ours = Self.skillState(at: directory, expected: [:]) == .outdated
            if ours, others.isEmpty {
                steps.append(.removeSkill(directory: directory))
            }
        }
        return AgentConnectPlan(agent: agent, state: steps.isEmpty ? .upToDate : .willChange, steps: steps, notes: [],
                                isConnected: current != nil, record: nil)
    }

    // MARK: Execute

    public func execute(_ plan: ConnectPlan) -> [AgentConnectResult] {
        var record = readRecord()
        var results: [AgentConnectResult] = []
        // Shared skill folders: install or remove each once.
        var handledSkills: Set<URL> = []
        for item in plan.agents {
            guard item.state == .willChange else {
                let outcome: AgentConnectResult.Outcome = if case .refused(let reason) = item.state { .failed(reason) } else { .unchanged }
                results.append(AgentConnectResult(agent: item.agent, outcome: outcome, notes: item.notes))
                continue
            }
            do {
                for step in item.steps {
                    switch step {
                    case .installSkill(let directory, _, _), .removeSkill(let directory):
                        if handledSkills.contains(directory) { continue }
                        handledSkills.insert(directory)
                    default: break
                    }
                    let folder: String? = switch step {
                    case .installSkill(let directory, _, _), .removeSkill(let directory): directory.deletingLastPathComponent().path
                    case .writeConfig(let file, nil, _, _, _), .removeFile(let file): file.deletingLastPathComponent().path
                    default: nil
                    }
                    let created = folder.flatMap(Self.firstMissingAncestor)
                    try run(step, agent: item.agent, mode: plan.mode, command: plan.command)
                    if let created {
                        record.createdFolders = (record.createdFolders ?? []) + [created]
                    }
                    switch step {
                    case .removeSkill, .removeFile:
                        if let folder { Self.removeEmptyFolders(from: folder, createdIn: &record) }
                    default: break
                    }
                }
                if plan.mode == .connect, let entry = item.record { record.agents[item.agent.rawValue] = entry }
                if plan.mode == .disconnect { record.agents[item.agent.rawValue] = nil }
                logger.info("\(plan.mode.rawValue, privacy: .public) \(item.agent.rawValue, privacy: .public): done")
                results.append(AgentConnectResult(agent: item.agent, outcome: .changed, notes: item.notes))
            } catch {
                logger.error("\(plan.mode.rawValue, privacy: .public) \(item.agent.rawValue, privacy: .public) failed")
                results.append(AgentConnectResult(agent: item.agent, outcome: .failed(Self.explain(error, agent: item.agent)), notes: item.notes))
            }
        }
        writeRecord(record)
        return results
    }

    private func run(_ step: ConnectStep, agent: ConnectAgent, mode: ConnectPlan.Mode, command: [String]) throws {
        let fm = FileManager.default
        switch step {
        case .writeConfig(let file, let before, let after, _, _):
            let now = try? Data(contentsOf: file)
            guard now == before else { throw ConnectError.changedSincePlan(file.lastPathComponent) }
            if let before { try backup(before, of: file, agent: agent) }
            let permissions = (try? fm.attributesOfItem(atPath: file.path))?[.posixPermissions]
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try after.write(to: file, options: .atomic)
            if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
        case .runCommand(let planned):
            let file = agent.configFile(home: home)
            if let data = try? Data(contentsOf: file) { try backup(data, of: file, agent: agent) }
            let result = try runner.run(planned)
            guard result.status == 0 else {
                throw ExecutorError.commandFailed(planned.commandLine, status: result.status, message: String(result.errorOutput.prefix(300)))
            }
            // Checked only after the last command of the step list (remove before add is fine).
            if planned.note != "Remove the old domovy entry" {
                let state = try registered(agent, in: try? Data(contentsOf: file))
                let ok = mode == .connect ? state == command : state == nil
                guard ok else { throw ConnectError.notVerified(planned.commandLine, file.lastPathComponent) }
            }
        case .installSkill(let directory, let files, let replacing):
            if replacing { try moveAside(directory, agent: agent) }
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, contents) in files.sorted(by: { $0.key < $1.key }) {
                try Data(contents.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
            }
        case .removeSkill(let directory):
            guard Self.skillState(at: directory, expected: [:]) != .foreign else { return }
            try moveAside(directory, agent: agent)
        case .removeFile(let file):
            try moveAside(file, agent: agent)
        }
    }

    /// Copies a config file into `<store>/Connect/Backups` before it changes.
    private func backup(_ data: Data, of file: URL, agent: ConnectAgent) throws {
        let folder = storeRoot.appendingPathComponent("Connect/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent("\(Self.stamp(now()))-\(agent.rawValue)-\(file.lastPathComponent)")
        try data.write(to: target, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    /// Moves something Domovy made to `<store>/Connect/Removed`, never deleting it.
    private func moveAside(_ url: URL, agent: ConnectAgent) throws {
        let folder = storeRoot.appendingPathComponent("Connect/Removed/\(Self.stamp(now()))-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: folder.appendingPathComponent("\(agent.rawValue)-\(url.lastPathComponent)"))
    }

    // MARK: Config formats

    /// The command registered under "domovy" (executable first), or `nil` when none is.
    func registered(_ agent: ConnectAgent, in data: Data?) throws -> [String]? {
        guard let data, !data.isEmpty else { return nil }
        let name = MCPRegistration.serverName
        if agent.isTOML {
            let text = String(decoding: data, as: UTF8.self)
            if TOMLTableEditor.hasOtherDefinition(of: ["mcp_servers", name], in: text) { throw ConnectError.unknownLayout(agent.configFile(home: home).lastPathComponent) }
            guard let range = TOMLTableEditor.range(of: ["mcp_servers", name], in: text) else { return nil }
            let block = text[range]
            guard let command = TOMLTableEditor.string("command", in: block) else { return [] }
            let argsLine = block.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("args") }
            let args = argsLine.flatMap { line -> [String]? in
                guard let value = line.split(separator: "=", maxSplits: 1).last else { return nil }
                return try? JSONDecoder().decode([String].self, from: Data(value.utf8))
            } ?? []
            return [command] + args
        }
        if data.allSatisfy(JSONCEditor.isSpace) { return nil }
        guard let value = try JSONCEditor.value(of: name, at: agent.serverPath(in: data), in: data) else { return nil }
        if let all = value["command"]?.arrayValue { return all.compactMap(\.stringValue) }
        guard let command = value["command"]?.stringValue else { return [] }
        return [command] + (value["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
    }

    private func edited(_ agent: ConnectAgent, data: Data, command: [String], replacing: Bool, previous: ConnectRecord.Entry?) throws -> (Data, ConnectRecord.Entry?) {
        let name = MCPRegistration.serverName
        let file = agent.configFile(home: home)
        if agent.isTOML {
            var text = String(decoding: data, as: UTF8.self)
            let block = "[mcp_servers.\(name)]\ncommand = \(TOMLTableEditor.quote(command[0]))\nargs = [\(command.dropFirst().map(TOMLTableEditor.quote).joined(separator: ", "))]\n"
            // Replacing the table connect appended: keep it the exact tail disconnect looks for.
            if replacing, var entry = previous, let old = entry.appendedTOML, text.hasSuffix(old),
               TOMLTableEditor.range(of: ["mcp_servers", name], in: text)?.upperBound == text.endIndex {
                let lead = String(old.prefix { $0 == "\n" })
                entry.appendedTOML = lead + block
                return (Data((String(text.dropLast(old.count)) + lead + block).utf8), entry)
            }
            if replacing, let range = TOMLTableEditor.range(of: ["mcp_servers", name], in: text) {
                let tail = text[range].hasSuffix("\n\n") ? "\n" : ""
                text.replaceSubrange(range, with: block + tail)
                return (Data(text.utf8), nil)
            }
            let appendix = TOMLTableEditor.appendix(for: block, after: text)
            return (Data((text + appendix).utf8), ConnectRecord.Entry(configFile: file.path, createdFile: false, appendedTOML: appendix))
        }
        let path = agent.serverPath(in: data.isEmpty ? nil : data)
        let siblings = (try? JSONCEditor.memberValues(at: path, in: data)) ?? [:]
        let value = agent.entry(command: command, path: path, siblings: siblings)
        if replacing, let replaced = try JSONCEditor.replacingValue(of: name, with: value, at: path, in: data) {
            return (replaced, nil)
        }
        let (after, insertion) = try JSONCEditor.inserting(name, value: value, at: path, in: data)
        return (after, ConnectRecord.Entry(configFile: file.path, createdFile: false, insertion: insertion))
    }

    private func removed(_ agent: ConnectAgent, data: Data, record: ConnectRecord.Entry?) throws -> Data {
        let name = MCPRegistration.serverName
        if agent.isTOML {
            let text = String(decoding: data, as: UTF8.self)
            guard let result = TOMLTableEditor.removing(["mcp_servers", name], from: text, appended: record?.appendedTOML) else { return data }
            return Data(result.utf8)
        }
        return try JSONCEditor.removing(name, at: agent.serverPath(in: data), in: data, insertion: record?.insertion) ?? data
    }

    // MARK: Skill

    /// Removes `folder` and its parents while they are empty, up to the outermost one connect
    /// created. Nothing of the user's is in an empty folder Domovy made itself.
    static func removeEmptyFolders(from folder: String, createdIn record: inout ConnectRecord) {
        guard let top = record.createdFolders?.first(where: { folder == $0 || folder.hasPrefix($0 + "/") }) else { return }
        let fm = FileManager.default
        var current = folder
        while (try? fm.contentsOfDirectory(atPath: current))?.isEmpty == true {
            try? fm.removeItem(atPath: current)
            if current == top { break }
            current = (current as NSString).deletingLastPathComponent
        }
        if !fm.fileExists(atPath: top) { record.createdFolders?.removeAll { $0 == top } }
    }

    /// The outermost folder on the way to `path` that does not exist yet, or `nil` when it exists.
    static func firstMissingAncestor(_ path: String) -> String? {
        var missing: String?
        var current = path
        while !current.isEmpty, current != "/", !FileManager.default.fileExists(atPath: current) {
            missing = current
            current = (current as NSString).deletingLastPathComponent
        }
        return missing
    }

    enum SkillState { case absent, current, outdated, foreign }

    /// Whether `directory` holds exactly `expected` (Domovy's skill for this command), another
    /// version of Domovy's skill, or someone else's. An empty `expected` never counts as current.
    static func skillState(at directory: URL, expected: [String: String]) -> SkillState {
        let file = directory.appendingPathComponent("SKILL.md")
        guard FileManager.default.fileExists(atPath: directory.path) else { return .absent }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .foreign }
        let matches = expected.allSatisfy { name, contents in
            (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) == contents
        }
        if !expected.isEmpty, matches { return .current }
        let frontmatter = text.components(separatedBy: "\n---").first ?? ""
        return frontmatter.contains("name: domovy") && frontmatter.contains("author: domovy") ? .outdated : .foreign
    }

    // MARK: Record

    private func readRecord() -> ConnectRecord {
        guard let data = try? Data(contentsOf: recordFile) else { return ConnectRecord() }
        return (try? JSONDecoder().decode(ConnectRecord.self, from: data)) ?? ConnectRecord()
    }

    private func writeRecord(_ record: ConnectRecord) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: recordFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: recordFile, options: .atomic)
    }

    // MARK: Text

    static func keyText(_ agent: ConnectAgent, _ data: Data?) -> String {
        agent.isTOML ? "[mcp_servers]" : agent.serverPath(in: data).joined(separator: ".")
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    static let missingCommand = "Domovy can't find a domo command to register. Domovy.app ships one inside; if this copy has none, install it with: brew install turman17/tap/domo"

    static func explain(_ error: any Error, agent: ConnectAgent) -> String {
        switch error {
        case let error as ConnectError: return error.message
        case JSONCEditor.EditError.notAnObject, JSONCEditor.EditError.notAnObjectAt, JSONCEditor.EditError.malformed:
            return "Domovy could not read \(agent.displayName)'s config as JSON, so it left the file as it is."
        default: return error.localizedDescription
        }
    }
}

enum ConnectError: Error {
    case appRunning(String)
    case changedSincePlan(String)
    case notVerified(String, String)
    case unknownLayout(String)

    var message: String {
        switch self {
        case .appRunning(let reasons): "Nothing was changed. " + reasons
        case .changedSincePlan(let name): "\(name) changed since the plan, so Domovy left it as it is. Try again."
        case .notVerified(let command, let name): "`\(command)` ran, but \(name) does not show the expected domovy entry. Check it with the agent's own `mcp list`."
        case .unknownLayout(let name): "\(name) defines domovy in a way Domovy does not edit, so it left the file as it is."
        }
    }
}
