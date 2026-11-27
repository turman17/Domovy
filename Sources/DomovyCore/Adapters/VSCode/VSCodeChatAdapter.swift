import Foundation

/// Adapter for VS Code's own chat (GitHub Copilot Chat and other chat participants), in VS Code,
/// VS Code Insiders and VSCodium. A chat is its files (`<id>.json`, `<id>.jsonl`), its edit
/// state folder and its entry in the chat list of a `state.vscdb`. Delete does what VS Code's
/// own delete does (`internalDeleteSession`, chatSessionStore.ts line 455): the files go (to the
/// Trash here) and the list entry is cut out of `chat.ChatSessionStore.index`. That edit is a
/// write to VS Code's database, so it runs only while VS Code is quit, after cloning the database
/// into the quarantine, the way Domovy edits Cursor's. Archive compresses the files in place.
public struct VSCodeChatAdapter: AgentAdapter {
    public let kind: AgentKind = .vsCodeChat
    /// The first VS Code build's `Application Support` folder (`Code`).
    public let root: URL

    let layouts: [VSCodeLayout]
    let openHandles: any OpenHandleChecker
    let processes: any RunningProcessLister

    public static let acknowledgement = "Undo puts VS Code's whole state database (state.vscdb) back as it was before this delete, so anything VS Code writes to it afterwards would be lost. Domovy refuses to undo once VS Code has changed the file; the chat's files still come back from the Trash."

    /// - Parameter home: the home whose `Library/Application Support/{Code, Code - Insiders, VSCodium}` are read.
    public init(home: URL, openHandles: any OpenHandleChecker = LibprocOpenHandleChecker.shared,
                processes: any RunningProcessLister = LibprocProcessLister()) {
        self.layouts = VSCodeLayout.layouts(home: home.standardizedFileURL)
        self.root = layouts[0].support
        self.openHandles = openHandles
        self.processes = processes
    }

    public var scope: [URL] { layouts.map(\.support) }

    private var present: [VSCodeLayout] { layouts.filter(\.isPresent) }

    // MARK: AgentAdapter

    public func status() async -> AdapterStatus {
        let installed = present
        guard !installed.isEmpty else { return .notInstalled }
        for layout in installed {
            for store in layout.stores() {
                guard let database = store.database, FileSystem.exists(database) else { continue }
                if !VSCodeState.hasItemTable(database) {
                    return .readOnly(reason: "A \(layout.flavor.name) state database has a layout Domovy does not know (no ItemTable), so it does not change its chats.")
                }
                if case .unknown = VSCodeChatIndex.load(database) {
                    return .readOnly(reason: "\(layout.flavor.name)'s chat list (chat.ChatSessionStore.index) has a shape Domovy does not know, so it does not change those chats.")
                }
            }
        }
        return .ready
    }

    public func sessions() async throws -> [Session] {
        let installed = present
        guard !installed.isEmpty else { throw AdapterError.notInstalled(kind) }
        var result: [Session] = []
        var seen = Set<String>()
        for layout in installed {
            let live = await liveness(layout)
            for store in layout.stores() {
                for chat in Self.chats(in: store) where seen.insert(chat.id).inserted {
                    result.append(makeSession(chat, layout: layout, store: store, live: live))
                }
            }
        }
        return result.sorted { $0.lastActive > $1.lastActive }
    }

    public func artifacts(of session: Session) async throws -> [Artifact] {
        let found = try locate(session)
        var artifacts = found.chat.files.map { Artifact(url: $0, kind: .file, sizeBytes: FileSystem.size(of: $0), note: Self.note(for: $0)) }
        if let editing = found.editing {
            artifacts.append(Artifact(url: editing, kind: .folder, sizeBytes: FileSystem.size(of: editing), note: "Edit state of the chat (chatEditingSessions)"))
        }
        if let database = found.store.database, found.chat.entry != nil {
            artifacts.append(Artifact(url: database, kind: .indexEntry, sizeBytes: found.chat.indexBytes,
                                      note: "Entry in \(found.layout.flavor.name)'s chat list (chat.ChatSessionStore.index)"))
        }
        return artifacts
    }

    public func liveCheck(_ session: Session) async throws -> LiveCheckResult {
        let found = try locate(session)
        return await liveness(found.layout, extra: found.chat.files)
    }

    public func deletePlan(for session: Session, destination: Destination = .trash) async throws -> Plan {
        let found = try locate(session)
        if case .unknown = found.index {
            throw AdapterError.readOnly(kind, reason: "\(found.layout.flavor.name)'s chat list has a shape Domovy does not know, so it does not change this chat.")
        }
        var moves = found.chat.files.map { FileMove(source: $0, kind: .file, sizeBytes: FileSystem.size(of: $0), note: Self.note(for: $0)) }
        if let editing = found.editing {
            moves.append(FileMove(source: editing, kind: .folder, sizeBytes: FileSystem.size(of: editing), note: "Edit state of the chat"))
        }
        var edits: [DatabaseEdit] = []
        var remarks: [String] = []
        if let database = found.store.database, found.chat.entry != nil {
            let removal = DatabaseEdit.ListEntryRemoval(
                table: "ItemTable", key: VSCodeLayout.indexKey, memberPath: ["entries"], id: session.id, bytes: found.chat.indexBytes,
                note: "Its entry in \(found.layout.flavor.name)'s chat list; the other entries stay byte for byte")
            edits.append(DatabaseEdit(database: database, files: SharedDatabaseLiveness.files(of: database), rows: [], listRemovals: [removal]))
            let copy = CleanupPlan.bytes(SharedDatabaseLiveness.files(of: database).reduce(Int64(0)) { $0 + FileSystem.size(of: $1) })
            remarks.append("\(found.layout.flavor.name)'s own delete removes the chat's files and its entry in the chat list. Domovy does the same with \(found.layout.flavor.name) quit: it keeps a copy of state.vscdb (\(copy)) in its quarantine first and checks the database afterwards.")
        }
        if found.chat.files.isEmpty {
            remarks.append("This chat has no file left; only its entry in the chat list goes.")
        } else if found.chat.entry == nil {
            remarks.append("\(found.layout.flavor.name)'s chat list has no entry for this chat, so only its files go.")
        }
        let base = await liveness(found.layout, extra: found.chat.files)
        let live = edits.isEmpty ? base : SharedDatabaseLiveness.forPlan(base, what: "\(found.layout.flavor.name)'s state database")
        return Plan(agent: kind, sessionID: session.id, action: .delete, destination: destination, moves: moves, indexEdits: [],
                    databaseEdits: edits, remarks: remarks, acknowledgement: edits.isEmpty ? nil : Self.acknowledgement,
                    mustNotBeRunning: [found.layout.flavor.matcher], liveCheck: live, scope: scope)
    }

    public func archivePlan(for session: Session) async throws -> Plan {
        let found = try locate(session)
        var compressions: [FileCompression] = []
        for file in found.chat.files where APFSCompression.isRegularFile(file) && !APFSCompression.isCompressed(file)
            && FileSystem.size(of: file) > APFSCompression.minimumUsefulSize {
            compressions.append(FileCompression(file: file, sizeBytes: APFSCompression.allocatedBytes(of: file),
                                                estimatedBytes: APFSCompression.estimatedCompressedBytes(of: file),
                                                modificationTime: FileSystem.modificationTime(of: file), note: Self.note(for: file)))
        }
        let remarks = found.chat.files.isEmpty ? ["This chat has no file left to compress; only its entry in the chat list remains."] : []
        return Plan(agent: kind, sessionID: session.id, action: .archive, destination: nil, moves: [], indexEdits: [],
                    compressions: compressions, remarks: remarks,
                    mustNotBeRunning: compressions.isEmpty ? [] : [found.layout.flavor.matcher],
                    liveCheck: await liveness(found.layout, extra: found.chat.files), scope: scope)
    }

    public func transcript(of session: Session, limit: Int, masking findings: [SecretFinding]) async throws -> Transcript {
        let found = try locate(session)
        guard let chat = found.chat.files.lazy.compactMap(VSCodeChatIndex.chat(at:)).first else { return .empty }
        return VSCodeChatIndex.transcript(of: chat, limit: limit)
    }

    public func footprint() async throws -> Footprint {
        let installed = present
        guard let first = installed.first else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: first.user)
        var sessions: [URL] = []
        var editing: [URL] = []
        for layout in installed {
            for store in layout.stores() {
                sessions.append(store.sessions)
                if let folder = store.editing { editing.append(folder) }
            }
        }
        builder.add("Chat sessions", sessions, reveal: first.user, .consequences,
                    "Chats with Copilot and other chat participants. Delete or archive them one by one in Sessions.", guidance: .manageInSessions)
        builder.add("Chat edit state", editing, reveal: first.user, .consequences,
                    "What VS Code needs to keep or undo a chat's file edits. It goes with each chat in Sessions.", guidance: .manageInSessions)
        for layout in installed {
            let copilot = layout.globalStorage.appendingPathComponent("github.copilot-chat", isDirectory: true)
            builder.add("Copilot Chat caches", ["commandEmbeddings.json", "settingEmbeddings.json"].map { copilot.appendingPathComponent($0) },
                        reveal: copilot, .safe, "Search indexes of VS Code's commands and settings. Copilot Chat downloads them again.")
            builder.add("Copilot Chat data", builder.unclaimedChildren(of: copilot), reveal: copilot, .keep,
                        "Copilot Chat's memories, agent definitions and its session store. Left alone.")
        }
        return builder.build()
    }

    // MARK: Chats

    struct Chat: Sendable {
        let id: String
        let files: [URL]
        let entry: VSCodeChatIndex.Entry?
        let indexBytes: Int64
    }

    /// Every chat of a store: files with or without an entry, and entries without a file unless
    /// VS Code marked them empty.
    static func chats(in store: VSCodeLayout.Store) -> [Chat] {
        let files = VSCodeChatIndex.files(in: store.sessions)
        var entries: [String: VSCodeChatIndex.Entry] = [:]
        var bytes: [String: Int64] = [:]
        if let database = store.database, case .known(let found, let sizes) = VSCodeChatIndex.load(database) {
            entries = found
            bytes = sizes
        }
        var ids = Set(files.keys)
        for entry in entries.values where !entry.isEmpty && SafeID.isSafe(entry.id) { ids.insert(entry.id) }
        return ids.sorted().map { Chat(id: $0, files: files[$0] ?? [], entry: entries[$0], indexBytes: bytes[$0] ?? 0) }
    }

    private func makeSession(_ chat: Chat, layout: VSCodeLayout, store: VSCodeLayout.Store, live: LiveCheckResult) -> Session {
        let editing = store.editing.map { $0.appendingPathComponent(chat.id, isDirectory: true) }
        let title = chat.entry?.title ?? chat.files.lazy.compactMap(VSCodeChatIndex.chat(at:)).first.flatMap(VSCodeChatIndex.title(of:))
        let modified = chat.files.compactMap(FileSystem.modificationDate).max()
        let size = chat.files.reduce(Int64(0)) { $0 + FileSystem.size(of: $1) } + (editing.map { FileSystem.size(of: $0) } ?? 0) + chat.indexBytes
        let archived = !chat.files.isEmpty && chat.files.allSatisfy(APFSCompression.isCompressed)
        return Session(id: chat.id, agent: kind, title: title, projectPath: store.project,
                       lastActive: chat.entry?.lastMessage ?? modified ?? store.database.flatMap(FileSystem.modificationDate) ?? .distantPast,
                       sizeBytes: size, status: live.isLive ? .live : archived ? .archived : .idle, expiresAt: nil,
                       transcriptURL: chat.files.first ?? store.database ?? store.sessions, isArchived: archived,
                       origin: layout.flavor.folder == "Code" ? nil : layout.flavor.name)
    }

    private static func note(for file: URL) -> String {
        file.pathExtension == "jsonl" ? "Chat (operation log)" : "Chat"
    }

    // MARK: Liveness

    /// VS Code writes its chats and its state database while it runs, so every chat of a running
    /// build counts as live, as does a chat whose files or database something holds open.
    private func liveness(_ layout: VSCodeLayout, extra: [URL] = []) async -> LiveCheckResult {
        let databases = layout.stores().compactMap(\.database).filter { FileSystem.exists($0) }
        return await SharedDatabaseLiveness.check(app: layout.flavor.matcher, files: databases.flatMap(SharedDatabaseLiveness.files(of:)) + extra,
                                                  what: "\(layout.flavor.name)'s chat files", processes: processes, openHandles: openHandles)
    }

    // MARK: Guards

    private struct Located {
        let layout: VSCodeLayout
        let store: VSCodeLayout.Store
        let chat: Chat
        let index: VSCodeChatIndex.State
        /// `chatEditingSessions/<id>`, when it exists.
        let editing: URL?
    }

    private func locate(_ session: Session) throws -> Located {
        guard session.agent == kind, SafeID.isSafe(session.id) else { throw AdapterError.sessionNotFound(session.id) }
        let target = session.transcriptURL.standardizedFileURL
        for layout in present {
            for store in layout.stores() {
                let belongs = target.deletingLastPathComponent() == store.sessions.standardizedFileURL
                    || target == store.database?.standardizedFileURL || target == store.sessions.standardizedFileURL
                guard belongs, let chat = Self.chats(in: store).first(where: { $0.id == session.id }) else { continue }
                let index = store.database.map(VSCodeChatIndex.load) ?? .absent
                let editing = store.editing.map { $0.appendingPathComponent(session.id, isDirectory: true) }.flatMap { FileSystem.exists($0) ? $0 : nil }
                return Located(layout: layout, store: store, chat: chat, index: index, editing: editing)
            }
        }
        throw AdapterError.sessionNotFound(session.id)
    }
}
