import Foundation

/// Orphan finder (PLAN.md section 4 A): companions and Desktop entries whose transcript is
/// gone, and duplicate copies left after a Desktop restart. Every cleanup is a plan.
extension ClaudeCodeAdapter {
    public func orphanReport() async -> OrphanReport {
        guard FileSystem.exists(root) else { return .empty }
        let index = TranscriptIndex(layout: layout)
        let desktop = desktopSnapshot()
        let cutoff = now().addingTimeInterval(-Self.orphanGracePeriod)

        var orphans = orphanedCompanions(slugs: index.slugs).map { url in
            item(.companion, url, id: url.lastPathComponent.lowercased())
        }
        // A registry entry this recent may belong to a session that has not written its transcript yet.
        for entry in desktop.entries where index.primary[entry.cliSessionID] == nil && (entry.modificationDate ?? .distantFuture) < cutoff {
            orphans.append(item(.desktopEntry, entry.file, id: entry.cliSessionID))
        }
        return OrphanReport(orphans: orphans, duplicates: duplicateGroups(index: index, desktop: desktop), desktopStatus: desktop.status)
    }

    /// Moves what `scope` found to `destination` and takes registry entries off Desktop's
    /// list. Items of live sessions stay; so does everything when Desktop's list is read-only.
    public func orphanPlan(_ scope: OrphanScope, destination: Destination = .trash) async throws -> Plan {
        try requireWritable()
        let report = await orphanReport()
        let desktop = desktopSnapshot()
        let items = scope == .orphans ? report.orphans : report.duplicateItems

        var moves: [FileMove] = []
        var removals: [RegistryRemoval] = []
        var remarks: [String] = []
        var liveIDs = Set<String>()
        var handles: [LiveCheckResult.OpenHandleStatus] = []
        var seen = Set<URL>()

        for item in items where seen.insert(item.url).inserted {
            switch item.kind {
            case .desktopEntry, .duplicateDesktopEntry:
                guard desktop.canMutate, let entry = desktop.entries.first(where: { $0.file == item.url }) else { continue }
                removals.append(ClaudeDesktopRegistry.removal(of: entry, note: Self.note(for: item)))
            case .companion, .duplicateCopy, .duplicateSession:
                let urls = item.kind == .duplicateSession ? sessionFiles(of: item) : [item.url]
                if urls.contains(where: layout.isProtected) { throw AdapterError.protectedPathInPlan(item.url) }
                let check = await liveness.check(sessionID: item.sessionID, artifactURLs: urls)
                handles.append(check.openHandles)
                guard !check.isLive else {
                    liveIDs.insert(item.sessionID)
                    continue
                }
                for url in urls where seen.insert(url).inserted || url == item.url {
                    moves.append(FileMove(source: url, kind: FileSystem.isDirectory(url) ? .folder : .file,
                                          sizeBytes: FileSystem.size(of: url), note: Self.note(for: item, file: url)))
                }
            }
        }
        if !liveIDs.isEmpty {
            remarks.append("\(liveIDs.count) live \(liveIDs.count == 1 ? "session keeps its files" : "sessions keep their files"); Domovy never touches a live session.")
        }
        if case .readOnly(let reason) = desktop.status, items.contains(where: { $0.kind == .desktopEntry || $0.kind == .duplicateDesktopEntry }) {
            remarks.append(reason)
        }
        if scope == .duplicates, !items.isEmpty {
            remarks.append("The newest copy of each conversation stays, by modification time, and so does any copy Claude Desktop points at.")
        }
        if !removals.isEmpty {
            remarks.append("Claude Desktop entries are backed up first, so undo puts them back.")
        }
        let base = LiveCheckResult(
            isLive: false,
            reasons: [],
            checkedSignals: ["sessions/*.json", "daemon/roster.json", "open file handles"],
            openHandles: handles.contains(.unavailable) || handles.isEmpty ? .unavailable : (handles.contains(.open) ? .open : .clear)
        )
        return Plan(
            agent: kind,
            sessionID: scope.rawValue,
            action: .delete,
            destination: destination,
            moves: moves,
            indexEdits: [],
            registryRemovals: removals,
            remarks: remarks,
            mustNotBeRunning: removals.isEmpty ? [] : [ClaudeDesktopRegistry.processMatcher],
            liveCheck: await desktopChecked(base, touchesRegistry: !removals.isEmpty),
            scope: self.scope
        )
    }

    // MARK: Duplicates

    private func duplicateGroups(index: TranscriptIndex, desktop: ClaudeDesktopRegistry.Snapshot) -> [DuplicateGroup] {
        var groups: [DuplicateGroup] = []
        let pointedAt = Set(desktop.entries.map(\.cliSessionID))

        // Set-aside copies next to a transcript that still exists. The primary always stays:
        // it is the file Claude Code resumes.
        for (id, copies) in index.setAside.sorted(by: { $0.key < $1.key }) {
            guard let primary = index.primary[id] else { continue }
            let newest = Self.newestFile([primary] + copies) ?? primary
            let kept = Set([primary, newest])
            let extra = copies.filter { !kept.contains($0) }.map { item(.duplicateCopy, $0, id: id) }
            if !extra.isEmpty { groups.append(DuplicateGroup(sessionID: id, kept: Array(kept).sorted { $0.path < $1.path }, extra: extra)) }
        }

        // One conversation continued under a new id after a Desktop restart: the registry names
        // the earlier ids in priorCliSessionIds.
        for entry in desktop.entries {
            let ids = ([entry.cliSessionID] + entry.priorCLISessionIDs).filter { index.primary[$0] != nil }
            guard ids.count > 1 else { continue }
            let transcripts = ids.compactMap { index.primary[$0] }
            let newest = Self.newestFile(transcripts)
            let extra = ids.filter { index.primary[$0] != newest && !pointedAt.contains($0) }
                .compactMap { id in index.primary[id].map { duplicateSession(id: id, transcript: $0) } }
            let kept = transcripts.filter { url in !extra.contains { $0.url == url } }
            if !extra.isEmpty { groups.append(DuplicateGroup(sessionID: entry.cliSessionID, kept: kept, extra: extra)) }
        }

        // Several registry entries for one transcript: the newest entry stays.
        for (id, entries) in desktop.byCLISessionID.sorted(by: { $0.key < $1.key }) where entries.count > 1 {
            guard let newest = Self.newest(entries) else { continue }
            let extra = entries.filter { $0.file != newest.file }.map { item(.duplicateDesktopEntry, $0.file, id: id) }
            groups.append(DuplicateGroup(sessionID: id, kept: [newest.file], extra: extra))
        }
        return groups
    }

    private func duplicateSession(id: String, transcript: URL) -> OrphanItem {
        let files = collectArtifacts(id: id, transcript: transcript).filter { $0.kind != .indexEntry }
        return OrphanItem(kind: .duplicateSession, url: transcript, sessionID: id,
                          sizeBytes: files.reduce(0) { $0 + $1.sizeBytes }, modified: FileSystem.modificationDate(of: transcript))
    }

    /// Every file and folder of an earlier copy; its history lines stay (they are prompts the user typed).
    private func sessionFiles(of item: OrphanItem) -> [URL] {
        collectArtifacts(id: item.sessionID, transcript: item.url).filter { $0.kind != .indexEntry }.map(\.url)
    }

    // MARK: Helpers

    private func item(_ kind: OrphanItem.Kind, _ url: URL, id: String) -> OrphanItem {
        OrphanItem(kind: kind, url: url, sessionID: id, sizeBytes: FileSystem.size(of: url), modified: FileSystem.modificationDate(of: url))
    }

    static func newestFile(_ urls: [URL]) -> URL? {
        urls.max { (FileSystem.modificationDate(of: $0) ?? .distantPast, $1.path) < (FileSystem.modificationDate(of: $1) ?? .distantPast, $0.path) }
    }

    private static func note(for item: OrphanItem, file: URL? = nil) -> String {
        let short = String(item.sessionID.prefix(8))
        switch item.kind {
        case .companion: return "Companion of session \(short), whose transcript is gone"
        case .desktopEntry: return "Desktop registry entry for \(short), whose transcript is gone; file removed"
        case .duplicateCopy: return "Older copy of transcript \(short); the newest stays"
        case .duplicateSession:
            return file == item.url ? "Earlier transcript \(short) of a conversation Desktop continued under a new id" : "Belongs to earlier transcript \(short)"
        case .duplicateDesktopEntry: return "Second Desktop registry entry for \(short); the newest stays, file removed"
        }
    }
}

/// Primary transcripts and set-aside copies by session id, from file names only.
struct TranscriptIndex {
    let slugs: [URL]
    var primary: [String: URL] = [:]
    var setAside: [String: [URL]] = [:]

    init(layout: ClaudeCodeLayout) {
        slugs = FileSystem.children(of: layout.projects).filter(FileSystem.isDirectory)
        for slug in slugs {
            for entry in FileSystem.children(of: slug) {
                let name = entry.lastPathComponent
                if let id = ClaudeCodeLayout.sessionID(ofTranscriptNamed: name) {
                    primary[id] = entry
                } else if let id = ClaudeCodeLayout.sessionID(ofSetAsideCopyNamed: name) {
                    setAside[id, default: []].append(entry)
                }
            }
        }
    }
}
