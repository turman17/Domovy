import Foundation

/// Adapter for the Gemini Code Assist extension in VS Code (and Insiders, VSCodium). Its chats
/// are members of one JSON value in VS Code's global `state.vscdb`. Delete cuts the chat's member
/// out of that value, every other byte staying as it was, only while VS Code is quit and after
/// cloning the database into the quarantine; its file checkpoints go to the Trash. Sign-in
/// (`google-vscode-extension/auth`) and the `cloudcode_cli` binary are never touched.
/// Archive has nothing to compress: no file belongs to one chat.
public struct GeminiCodeAssistAdapter: AgentAdapter {
    public let kind: AgentKind = .geminiCodeAssist
    public let root: URL

    let layouts: [VSCodeLayout]
    let home: URL
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    public static let acknowledgement = "Undo puts VS Code's whole state database (state.vscdb) back as it was before this delete, so anything VS Code writes to it afterwards would be lost. Domovy refuses to undo once VS Code has changed the file; the chat is then gone for good."

    public static let archiveRemark = "Gemini Code Assist keeps this chat inside VS Code's state database, not in a file of its own, so there is nothing to compress. Domovy leaves it as it is."

    public init(home: URL, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker.shared,
                processes: any RunningProcessLister = LibprocProcessLister()) {
        self.home = home.standardizedFileURL
        self.layouts = VSCodeLayout.layouts(home: self.home)
        self.root = layouts[0].globalStorage.appendingPathComponent(GeminiCodeAssistIndex.extensionFolder, isDirectory: true)
        self.openHandles = openHandles
        self.processes = processes
    }

    public var scope: [URL] { layouts.map(\.globalStorage) }

    /// Builds whose global state has Gemini Code Assist's value or its folder.
    private var present: [VSCodeLayout] {
        layouts.filter { layout in
            FileSystem.isDirectory(extensionFolder(layout)) || VSCodeState.value(GeminiCodeAssistIndex.key, in: layout.globalDatabase) != nil
        }
    }

    private func extensionFolder(_ layout: VSCodeLayout) -> URL {
        layout.globalStorage.appendingPathComponent(GeminiCodeAssistIndex.extensionFolder, isDirectory: true)
    }

    private func checkpoints(_ layout: VSCodeLayout) -> URL {
        extensionFolder(layout).appendingPathComponent("chat_checkpoint_files", isDirectory: true)
    }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        let installed = present
        guard !installed.isEmpty else { return .notInstalled }
        for layout in installed {
            if case .unknown(let reason) = GeminiCodeAssistIndex.load(layout.globalDatabase) { return .readOnly(reason: reason) }
        }
        return .ready
    }

    public func sessions() async throws -> [Session] {
        let installed = present
        guard !installed.isEmpty else { throw AdapterError.notInstalled(kind) }
        var result: [Session] = []
        for layout in installed {
            guard case .known(let threads, _) = GeminiCodeAssistIndex.load(layout.globalDatabase) else { continue }
            let live = await liveness(layout)
            let fallback = FileSystem.modificationDate(of: layout.globalDatabase) ?? .distantPast
            for thread in threads where SafeID.isSafe(thread.id) {
                let folders = checkpointFolders(of: thread, in: layout)
                result.append(Session(id: thread.id, agent: kind, title: thread.title, projectPath: thread.project,
                                      lastActive: thread.updatedAt ?? thread.createdAt ?? fallback,
                                      sizeBytes: thread.bytes + folders.reduce(0) { $0 + FileSystem.size(of: $1) },
                                      status: live.isLive ? .live : .idle, expiresAt: nil, transcriptURL: layout.globalDatabase,
                                      origin: layout.flavor.folder == "Code" ? nil : layout.flavor.name))
            }
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let (layout, thread, _) = try locate(session)
        var artifacts = [Artifact(url: layout.globalDatabase, kind: .indexEntry, sizeBytes: thread.bytes,
                                  note: "The chat, inside the google.geminicodeassist value of state.vscdb")]
        artifacts += checkpointFolders(of: thread, in: layout).map {
            Artifact(url: $0, kind: .folder, sizeBytes: FileSystem.size(of: $0), note: "File checkpoints of a reply")
        }
        return artifacts
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        let (layout, _, _) = try locate(session)
        return await liveness(layout)
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        let (layout, thread, state) = try locate(session)
        if case .unknown(let reason) = state { throw AdapterError.readOnly(kind, reason: reason) }
        guard SafeID.isSafe(thread.id) else { throw AdapterError.unsafeID(kind, id: thread.id) }
        let removal = DatabaseEdit.ListEntryRemoval(
            table: "ItemTable", key: GeminiCodeAssistIndex.key, memberPath: [GeminiCodeAssistIndex.threadsField, thread.scope],
            id: thread.id, bytes: thread.bytes,
            note: "The chat inside Gemini Code Assist's saved state; its other chats and settings stay byte for byte")
        let database = layout.globalDatabase
        let edit = DatabaseEdit(database: database, files: SharedDatabaseLiveness.files(of: database), rows: [], listRemovals: [removal])
        let moves = checkpointFolders(of: thread, in: layout).map {
            FileMove(source: $0, kind: .folder, sizeBytes: FileSystem.size(of: $0), note: "File checkpoints of a reply")
        }
        let copy = CleanupPlan.bytes(edit.files.reduce(Int64(0)) { $0 + FileSystem.size(of: $1) })
        var remarks = [
            "Gemini Code Assist deletes a chat from Resume Previous Chat. Domovy does the same with \(layout.flavor.name) quit: it cuts this chat out of the extension's saved state in state.vscdb, keeping a copy of the database (\(copy)) in its quarantine first and checking it afterwards.",
        ]
        if thread.ranAgentMode {
            remarks.append("This chat ran in agent mode, which also wrote a Gemini CLI chat in ~/.gemini. Domovy leaves that one; it is listed under Gemini CLI.")
        }
        let live = SharedDatabaseLiveness.forPlan(await liveness(layout), what: "\(layout.flavor.name)'s state database")
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: moves, indexEdits: [],
                    databaseEdits: [edit], remarks: remarks, acknowledgement: Self.acknowledgement,
                    mustNotBeRunning: [layout.flavor.matcher], liveCheck: live, scope: scope)
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        let (layout, _, _) = try locate(session)
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    remarks: [Self.archiveRemark], liveCheck: await liveness(layout), scope: scope)
    }

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let (layout, thread, _) = try locate(session)
        return GeminiCodeAssistIndex.transcript(layout.globalDatabase, id: thread.id, limit: limit)
    }

    public func footprint() async throws -> Footprint {
        let installed = present
        guard let first = installed.first else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: extensionFolder(first))
        for layout in installed {
            if case .known(let threads, let bytes) = GeminiCodeAssistIndex.load(layout.globalDatabase) {
                let n = threads.count
                builder.add("Chats", part: DiskUsage(allocated: bytes, logical: bytes), of: [layout.globalDatabase], reveal: layout.globalStorage,
                            .consequences, "\(n) \(n == 1 ? "chat" : "chats") kept inside VS Code's state database. Delete them one by one in Sessions with VS Code quit.",
                            guidance: .manageInSessions)
            }
            builder.add("Chat checkpoints", checkpoints(layout), .consequences,
                        "Copies of files before a reply changed them, for restoring. They go with each chat in Sessions; the extension prunes ones no chat uses.",
                        guidance: .manageInSessions)
            builder.add("Extension data", builder.unclaimedChildren(of: extensionFolder(layout)), reveal: extensionFolder(layout), .keep,
                        "Other state of the extension. Left alone.")
        }
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        builder.add("Agent tools", support.appendingPathComponent("cloud-code", isDirectory: true), .keep,
                    "The cloudcode_cli binary and logs the extension runs. It downloads them again if removed, but Domovy leaves them.")
        builder.add("Sign-in", support.appendingPathComponent("google-vscode-extension", isDirectory: true), .keep,
                    "Your Google sign-in for the extension. Never removed.")
        return builder.build()
    }

    // MARK: Helpers

    /// Checkpoint folders named by the trace ids of the chat's replies.
    private func checkpointFolders(of thread: GeminiCodeAssistIndex.Thread, in layout: VSCodeLayout) -> [URL] {
        Array(Set(thread.traceIDs)).sorted().filter(SafeID.isSafe).map { checkpoints(layout).appendingPathComponent($0, isDirectory: true) }
            .filter(FileSystem.isDirectory)
    }

    private func liveness(_ layout: VSCodeLayout) async -> LiveCheckResult {
        await SharedDatabaseLiveness.check(app: layout.flavor.matcher, files: SharedDatabaseLiveness.files(of: layout.globalDatabase),
                                           what: "\(layout.flavor.name)'s state database", processes: processes, openHandles: openHandles)
    }

    private func locate(_ session: Session) throws -> (VSCodeLayout, GeminiCodeAssistIndex.Thread, GeminiCodeAssistIndex.State) {
        guard session.agent == kind else { throw AdapterError.sessionNotFound(session.id) }
        for layout in layouts where layout.globalDatabase.standardizedFileURL == session.transcriptURL.standardizedFileURL {
            let state = GeminiCodeAssistIndex.load(layout.globalDatabase)
            if case .known(let threads, _) = state, let thread = threads.first(where: { $0.id == session.id }) {
                return (layout, thread, state)
            }
        }
        throw AdapterError.sessionNotFound(session.id)
    }
}
