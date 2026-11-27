import Foundation

/// Where Roo Code keeps its tasks, read from RooCodeInc/Roo-Code@b867ec91 (docs/research/agent_storage_formats.md,
/// Q9; not verified on a real install). Permalink base:
/// https://github.com/RooCodeInc/Roo-Code/blob/b867ec9145750d0ae1ff7f02d35406e9bf2a0b16/
///
/// - Storage is the editor's `globalStorage/rooveterinaryinc.roo-cline/` (src/utils/storage.ts#L14-L58,
///   src/package.json#L2-L5), in VS Code, its forks and Cursor alike. The `roo-cline.customStoragePath`
///   setting can move it elsewhere; Domovy does not follow that setting.
/// - A task is `tasks/<uuid v7>/` (src/core/task/Task.ts#L454) holding `api_conversation_history.json`,
///   `ui_messages.json`, `task_metadata.json`, `history_item.json`, `command-output/` and a
///   per-task `checkpoints/` git repository (src/shared/globalFileNames.ts#L1-L9,
///   src/services/checkpoints/RepoPerTaskCheckpointService.ts#L10).
/// - `history_item.json` is the source of truth for the task list: `{id, number, ts, task, size,
///   workspace, parentTaskId, childIds, …}` (packages/types/src/history.ts#L7-L29,
///   src/core/task-persistence/TaskHistoryStore.ts#L23-L30, #L160-L185). `tasks/_index.json` is a
///   cache Roo rebuilds: a folder that is gone is dropped at start, on its fs.watch or within five
///   minutes (TaskHistoryStore.ts#L80-L100, #L244-L290). The copy in `state.vscdb` is overwritten from
///   that store (src/core/webview/ClineProvider.ts#L2285-L2300).
/// - Roo's own delete removes the task and its child tasks: their `history_item.json`, the
///   `roo-<id>` branch of a legacy shared checkpoint repo, then the folders (ClineProvider.ts#L1736-L1821).
struct RooCodeStore: Sendable, Hashable {
    let editor: String
    /// `…/globalStorage/rooveterinaryinc.roo-cline`.
    let folder: URL
    let matcher: ProcessMatcher

    static let extensionID = "rooveterinaryinc.roo-cline"

    var tasks: URL { folder.appendingPathComponent("tasks", isDirectory: true) }

    /// VS Code, VS Code Insiders, VSCodium and Cursor (and Windsurf, a VS Code fork too).
    static func stores(home: URL) -> [RooCodeStore] {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let editors: [(String, String, ProcessMatcher)] = VSCodeFlavor.all.map { ($0.name, $0.folder, $0.matcher) } + [
            ("Cursor", "Cursor", CursorLayout.appMatcher),
            ("Windsurf", "Windsurf", ProcessMatcher(appName: "Windsurf", names: [], prefixes: ["windsurf helper"], exactNames: ["Windsurf"],
                                                    quitAdvice: "Quit Windsurf completely first.")),
        ]
        return editors.map { name, folder, matcher in
            RooCodeStore(editor: name, folder: support.appendingPathComponent("\(folder)/User/globalStorage/\(extensionID)", isDirectory: true).standardizedFileURL,
                         matcher: matcher)
        }
    }

    /// Entries of the extension folder Roo needs (settings, MCP servers, custom modes, caches).
    func isProtected(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: folder) else { return false }
        let parts = relative.split(separator: "/").map(String.init)
        return parts.first != "tasks" || parts.count < 2 || parts[1].hasPrefix("_") || parts[1].hasPrefix(".")
    }

    struct Task: Sendable {
        let id: String
        let folder: URL
        let title: String?
        let created: Date?
        let workspace: String?
        let parentID: String?
        let childIDs: [String]
    }

    /// Task folders with a readable `history_item.json` whose id is the folder's, as Roo's own
    /// reconcile requires (TaskHistoryStore.ts#L244-L290).
    func tasksByID() -> [String: Task] {
        var result: [String: Task] = [:]
        for folder in FileSystem.children(of: tasks) where FileSystem.isDirectory(folder) {
            let id = folder.lastPathComponent
            guard SafeID.isSafe(id), !id.hasPrefix("_"),
                  let item = FileSessions.object(folder.appendingPathComponent("history_item.json")), item["id"] as? String == id else { continue }
            result[id] = Task(id: id, folder: folder.standardizedFileURL, title: FileSessions.title(item["task"] as? String),
                              created: FileSessions.epoch(item["ts"]), workspace: (item["workspace"] as? String).flatMap { $0.hasPrefix("/") ? $0 : nil },
                              parentID: item["parentTaskId"] as? String,
                              childIDs: (item["childIds"] as? [String] ?? []).filter(SafeID.isSafe))
        }
        return result
    }

    /// Unknown when a task folder's `history_item.json` lacks the fields Domovy reads.
    func unknownLayout() -> String? {
        for folder in FileSystem.children(of: tasks).prefix(200) where FileSystem.isDirectory(folder) && !folder.lastPathComponent.hasPrefix("_") {
            let file = folder.appendingPathComponent("history_item.json")
            guard FileSystem.exists(file) else { continue }
            guard let item = FileSessions.object(file), item["id"] is String, item["ts"] is NSNumber, item["task"] is String else {
                return "A Roo Code task in \(editor) has a history_item.json Domovy does not know (id, ts and task are expected), so it only lists what it can read."
            }
        }
        return nil
    }
}

/// Adapter for Roo Code. Delete moves the task folder, and those of its child tasks, to the Trash
/// or the quarantine with the editor quit, the way Roo's own delete removes them; Roo drops the
/// task from its list cache when it next reconciles. Archive compresses the task's files in place.
/// `state.vscdb` and `tasks/_index.json` are never edited.
public struct RooCodeAdapter: AgentAdapter {
    public let kind: AgentKind = .rooCode
    public let root: URL

    let stores: [RooCodeStore]
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    public init(home: URL, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker.shared,
                processes: any RunningProcessLister = LibprocProcessLister()) {
        self.stores = RooCodeStore.stores(home: home.standardizedFileURL)
        self.root = stores[0].folder
        self.openHandles = openHandles
        self.processes = processes
    }

    public var scope: [URL] { stores.map(\.folder) }

    private var present: [RooCodeStore] { stores.filter { FileSystem.isDirectory($0.folder) } }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        let installed = present
        guard !installed.isEmpty else { return .notInstalled }
        for store in installed {
            if FileSystem.exists(store.tasks), !FileSystem.isDirectory(store.tasks) {
                return .readOnly(reason: "Roo Code's tasks in \(store.editor) are not a folder, which Domovy does not know from any Roo Code version.")
            }
            if let reason = store.unknownLayout() { return .readOnly(reason: reason) }
        }
        return .ready
    }

    public func sessions() async throws -> [Session] {
        let installed = present
        guard !installed.isEmpty else { throw AdapterError.notInstalled(kind) }
        var rows: [(RooCodeStore, RooCodeStore.Task, [RooCodeStore.Task])] = []
        for store in installed {
            let tasks = store.tasksByID()
            for task in tasks.values where task.parentID.map({ tasks[$0] == nil }) ?? true {
                rows.append((store, task, descendants(of: task, in: tasks)))
            }
        }
        let holders = await openHandleHolders(of: rows.map { ([$1] + $2).map(\.folder) }, checker: openHandles)
        return zip(rows, holders).map { row, holders in
            let (store, task, children) = row
            let folders = ([task] + children).map(\.folder)
            let lastActive = folders.compactMap { FileSystem.modificationDate(of: $0.appendingPathComponent("ui_messages.json")) }.max()
                ?? task.created ?? .distantPast
            let archived = APFSCompression.isCompressed(task.folder.appendingPathComponent("ui_messages.json"))
            let live = liveness(folders, holders: holders)
            return Session(id: task.id, agent: kind, title: task.title, projectPath: task.workspace, lastActive: lastActive,
                           sizeBytes: folders.reduce(0) { $0 + FileSystem.size(of: $1) },
                           status: live.isLive ? .live : archived ? .archived : .idle, expiresAt: nil,
                           transcriptURL: task.folder.appendingPathComponent("ui_messages.json"), isArchived: archived,
                           origin: store.editor == "VS Code" ? nil : store.editor)
        }
        .sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let target = try locate(session)
        return artifacts(target)
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        guard let result = await liveChecks(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try result.get()
    }

    public func liveChecks(for sessions: [Session]) async -> [Result<LiveCheckResult, any Error>] {
        await FileSessions.liveChecks(for: sessions, checker: openHandles, locate: locate, files: folders, liveness: { liveness(folders($0), holders: $1) })
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        guard let planned = await deletePlans(for: [session], destination: destination).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    public func deletePlans(for sessions: [Session], destination: Destination) async -> [PlannedSession] {
        let state = await status()
        return await FileSessions.plans(
            for: sessions, checker: openHandles, locate: locate, files: folders, liveness: { liveness(folders($0), holders: $1) },
            finish: { session, target, live in
                if case .readOnly(let reason) = state { throw AdapterError.readOnly(kind, reason: reason) }
                let artifacts = artifacts(target)
                for artifact in artifacts where target.store.isProtected(artifact.url) { throw AdapterError.protectedPathInPlan(artifact.url) }
                var remarks = ["Roo Code deletes a task by removing its folder and those of its subtasks. Domovy does the same with \(target.store.editor) quit; Roo drops the task from its list when it next starts."]
                if !target.children.isEmpty {
                    let n = target.children.count
                    remarks.append("Also moves its \(n) \(n == 1 ? "subtask" : "subtasks"), as Roo Code does.")
                }
                remarks.append("A `roo-\(session.id)` branch may stay in an older shared checkpoint repository (globalStorage/…/checkpoints/); it holds no files of its own. \(target.store.editor)'s state.vscdb is left as it is.")
                let blocking = processes.blockingReasons([target.store.matcher])
                return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination,
                            moves: artifacts.map { FileMove(source: $0.url, kind: $0.kind, sizeBytes: $0.sizeBytes, note: $0.note) }, indexEdits: [],
                            remarks: remarks, mustNotBeRunning: [target.store.matcher],
                            liveCheck: FileSessions.forPlan(live, blocking: blocking, app: target.store.editor), scope: scope)
            })
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        guard let planned = await archivePlans(for: [session]).first else { throw AdapterError.sessionNotFound(session.id) }
        return try planned.result.get()
    }

    /// Compresses the conversation files of the task and its subtasks; the checkpoint git
    /// repositories are left alone (git compresses its objects already).
    public func archivePlans(for sessions: [Session]) async -> [PlannedSession] {
        let state = await status()
        return await FileSessions.plans(
            for: sessions, checker: openHandles, locate: locate, files: folders, liveness: { liveness(folders($0), holders: $1) },
            finish: { session, target, live in
                if case .readOnly(let reason) = state { throw AdapterError.readOnly(kind, reason: reason) }
                let files = folders(target).flatMap { folder in
                    ["api_conversation_history.json", "ui_messages.json"].map {
                        Artifact(url: folder.appendingPathComponent($0), kind: .file, sizeBytes: 0, note: $0 == "ui_messages.json" ? "Chat messages" : "Model conversation")
                    }
                }.filter { FileSystem.exists($0.url) }
                let compressions = try FileSessions.compressions(of: files, isProtected: target.store.isProtected)
                return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                            compressions: compressions, liveCheck: live, scope: scope)
            })
    }

    /// `ui_messages.json`: the first `say: text` is the task, later `say: text` and
    /// `completion_result` are Roo's replies, `user_feedback` is the user (packages/types/src/message.ts#L144-L275,
    /// src/core/task/Task.ts#L1908, #L2029). Text is masked by the secret rules before it is shown.
    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let target = try locate(session)
        let file = target.task.folder.appendingPathComponent("ui_messages.json")
        guard FileSystem.size(of: file) <= 16 * 1024 * 1024 else { return .empty }
        guard let data = try? Data(contentsOf: file), let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw AdapterError.unreadable(file, reason: "it is not the JSON list Roo Code writes")
        }
        let masker = TranscriptMask.TextMasker()
        var messages: [TranscriptMessage] = []
        for (index, item) in items.enumerated() where item["type"] as? String == "say" && item["partial"] as? Bool != true {
            let say = item["say"] as? String
            let role: TranscriptMessage.Role
            switch say {
            case "text": role = messages.isEmpty ? .user : .assistant
            case "user_feedback": role = .user
            case "completion_result": role = .assistant
            default: continue
            }
            guard let text = (item["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
            if messages.count == limit { return Transcript(messages: messages, isTruncated: true) }
            messages.append(TranscriptMessage(id: "r\(index)", role: role, timestamp: FileSessions.epoch(item["ts"]), blocks: [.text(masker.mask(text))]))
        }
        return Transcript(messages: messages, isTruncated: false)
    }

    // MARK: Helpers

    struct Target: Sendable {
        let store: RooCodeStore
        let task: RooCodeStore.Task
        let children: [RooCodeStore.Task]
    }

    private func folders(_ target: Target) -> [URL] { ([target.task] + target.children).map(\.folder) }

    private func artifacts(_ target: Target) -> [Artifact] {
        [Artifact(url: target.task.folder, kind: .folder, sizeBytes: FileSystem.size(of: target.task.folder), note: "Task folder: conversation, messages, checkpoints")]
            + target.children.map { Artifact(url: $0.folder, kind: .folder, sizeBytes: FileSystem.size(of: $0.folder), note: "Subtask folder") }
    }

    /// Children by `childIds` and by `parentTaskId`, depth first, each once.
    private func descendants(of task: RooCodeStore.Task, in tasks: [String: RooCodeStore.Task]) -> [RooCodeStore.Task] {
        var seen: Set<String> = [task.id]
        var result: [RooCodeStore.Task] = []
        var queue = [task]
        while let next = queue.popLast() {
            let ids = Set(next.childIDs).union(tasks.values.filter { $0.parentID == next.id }.map(\.id))
            for id in ids.sorted() where seen.insert(id).inserted {
                guard let child = tasks[id] else { continue }
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// Roo writes no marker for a running task. Live when a file of it is open, or a
    /// `proper-lockfile` lock (`<file>.lock`, src/utils/safeWriteJson.ts#L56-L71) shows a write in progress.
    private func liveness(_ folders: [URL], holders: [OpenHandleHolder]?) -> LiveCheckResult {
        let writing = folders.contains { folder in FileSystem.children(of: folder).contains { $0.pathExtension == "lock" } }
        return FileSessions.liveness(markers: writing ? ["Roo Code is writing this task right now. Wait for it to finish."] : [],
                                     holders: holders, signals: ["write locks"])
    }

    private func locate(_ session: Session) throws -> Target {
        let folder = session.transcriptURL.standardizedFileURL.deletingLastPathComponent()
        guard session.agent == kind, SafeID.isSafe(session.id), folder.lastPathComponent == session.id,
              let store = stores.first(where: { $0.tasks.standardizedFileURL == folder.deletingLastPathComponent().standardizedFileURL }) else {
            throw AdapterError.sessionNotFound(session.id)
        }
        let tasks = store.tasksByID()
        guard let task = tasks[session.id] else { throw AdapterError.sessionNotFound(session.id) }
        return Target(store: store, task: task, children: descendants(of: task, in: tasks))
    }
}

extension RooCodeAdapter {
    public func footprint() async throws -> Footprint {
        let installed = present
        guard let first = installed.first else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: first.folder)
        for store in installed {
            let count = store.tasksByID().count
            builder.add("Tasks (\(store.editor))", store.tasks, .consequences,
                        "\(count) \(count == 1 ? "task" : "tasks") with their checkpoints. Delete or archive them one by one in Sessions.", guidance: .manageInSessions)
            builder.add("Checkpoints, older layout (\(store.editor))", store.folder.appendingPathComponent("checkpoints", isDirectory: true), .consequences,
                        "Shared checkpoint repositories of older Roo Code versions, one per workspace. Roo Code still reads them to restore old tasks.")
            builder.add("Settings and caches (\(store.editor))", builder.unclaimedChildren(of: store.folder), reveal: store.folder, .keep,
                        "Roo Code's settings, MCP servers, custom modes and caches. Left alone.")
        }
        return builder.build()
    }
}
