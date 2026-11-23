import Foundation

/// One quarantined file Purge originals can delete: plaintext secrets, or a copy kept before a
/// tool deleted the original.
public struct PurgeItem: Hashable, Codable, Sendable {
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// The original of a redacted file, kept for undo.
        case redactedOriginal
        /// A deleted session the secret scan had flagged, moved to the quarantine.
        case flaggedSession
        /// A copy kept before a tool deleted the original (`ollama rm`, `hf cache rm`,
        /// `codex delete`). Its disk space comes back only when it is purged.
        case toolCopy
    }

    public let entryID: UUID
    public let agent: AgentKind
    public let sessionID: String
    /// The file or folder inside Domovy's quarantine that will be deleted.
    public let file: URL
    /// Where it came from, for display.
    public let originalPath: URL
    public let sizeBytes: Int64
    public let reason: Reason
}

/// Exactly what Purge originals deletes. This is the only permanent delete in Domovy, so it is
/// a plan of its own, shown in full and confirmed separately.
public struct PurgePlan: Sendable {
    public let items: [PurgeItem]

    public var isEmpty: Bool { items.isEmpty }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    public var entryCount: Int { Set(items.map(\.entryID)).count }

    public var summary: String {
        guard !items.isEmpty else { return "Nothing to purge: Domovy's quarantine holds no originals or kept copies." }
        let n = items.count
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "Permanently deletes \(n) \(n == 1 ? "file" : "files") (\(size)) from Domovy's quarantine. This cannot be undone, and Domovy can no longer undo \(entryCount == 1 ? "the action" : "the \(entryCount) actions") they came from."
    }
}

extension Executor {
    /// Quarantined files that hold plaintext secrets: originals of redactions that were not
    /// undone, and, with `.flaggedSession`, sessions deleted to the quarantine after the scan
    /// flagged them. With `.toolCopy`, copies kept before a tool deleted the originals.
    /// Computing the plan changes nothing.
    public func purgePlan(_ reasons: Set<PurgeItem.Reason> = Set(PurgeItem.Reason.allCases)) throws -> PurgePlan {
        var items: [PurgeItem] = []
        for entry in try undoLog.entries() {
            // Database copies of an entry whose undo is no longer possible still take space.
            if reasons.contains(.toolCopy), entry.undoneAt == nil, entry.originalsPurgedAt == nil {
                for item in entry.snapshots {
                    guard let copy = item.copy, isInQuarantine(copy), FileSystem.itemExists(copy) else { continue }
                    items.append(PurgeItem(entryID: entry.id, agent: entry.agent, sessionID: entry.sessionID, file: copy,
                                           originalPath: item.original, sizeBytes: FileSystem.size(of: copy), reason: .toolCopy))
                }
            }
            guard entry.isUndoable else { continue }
            if reasons.contains(.redactedOriginal), entry.action == .redact {
                for item in entry.redacted where isInQuarantine(item.original) && FileSystem.exists(item.original) {
                    items.append(PurgeItem(entryID: entry.id, agent: entry.agent, sessionID: entry.sessionID, file: item.original,
                                           originalPath: item.file, sizeBytes: FileSystem.size(of: item.original), reason: .redactedOriginal))
                }
            }
            if reasons.contains(.flaggedSession), entry.action == .delete, entry.secretFindingCount > 0 {
                for item in entry.moved where isInQuarantine(item.current) && FileSystem.exists(item.current) {
                    items.append(PurgeItem(entryID: entry.id, agent: entry.agent, sessionID: entry.sessionID, file: item.current,
                                           originalPath: item.original, sizeBytes: FileSystem.size(of: item.current), reason: .flaggedSession))
                }
                // Byte-exact backups of index files hold the session's lines too (its prompts in
                // history.jsonl); purging them also drops the lines kept in the entry itself.
                let backups = entry.indexRestores.map { ($0.backup, $0.file) } + entry.registryRestores.map { ($0.backup, $0.file) }
                for (backup, original) in backups where isBackup(backup, of: entry) && FileSystem.itemExists(backup) {
                    items.append(PurgeItem(entryID: entry.id, agent: entry.agent, sessionID: entry.sessionID, file: backup,
                                           originalPath: original, sizeBytes: FileSystem.size(of: backup), reason: .flaggedSession))
                }
            }
            if reasons.contains(.toolCopy) {
                for item in entry.moved where item.kept != nil && isInQuarantine(item.current) && FileSystem.itemExists(item.current)
                    && !items.contains(where: { $0.file == item.current }) {
                    items.append(PurgeItem(entryID: entry.id, agent: entry.agent, sessionID: entry.sessionID, file: item.current,
                                           originalPath: item.original, sizeBytes: FileSystem.size(of: item.current), reason: .toolCopy))
                }
            }
        }
        return PurgePlan(items: items)
    }

    /// Permanently deletes exactly the plan's files, nothing else, and marks their undo entries
    /// as purged. Refuses anything outside the quarantine folder.
    @discardableResult
    public func purge(_ plan: PurgePlan) throws -> [UndoEntry] {
        try undoLog.withLock { try purgeNow(plan) }
    }

    private func purgeNow(_ plan: PurgePlan) throws -> [UndoEntry] {
        var entries = try undoLog.entries().filter { entry in plan.items.contains { $0.entryID == entry.id } }
        for item in plan.items {
            let inBackups = entries.first { $0.id == item.entryID }.map { isBackup(item.file, of: $0) } ?? false
            guard isInQuarantine(item.file) || inBackups else { throw ExecutorError.notInQuarantine(item.file) }
        }
        var removed = 0
        for item in plan.items where FileSystem.itemExists(item.file) {
            try fileManager.removeItem(at: item.file)
            removed += 1
        }
        let stamp = now()
        let purged = Set(plan.items.map(\.file))
        for index in entries.indices {
            entries[index].originalsPurgedAt = stamp
            // The removed lines, verbatim, go with their backup: nothing can put them back now.
            if entries[index].indexRestores.contains(where: { purged.contains($0.backup) }) { entries[index].indexRestores = [] }
            try undoLog.write(entries[index])
            let backups = undoLog.backupDirectory(for: entries[index])
            if FileSystem.exists(backups), FileSystem.children(of: backups).isEmpty { try? fileManager.removeItem(at: backups) }
            let folder = quarantineDirectory.appendingPathComponent(entries[index].id.uuidString, isDirectory: true)
            if FileSystem.exists(folder), FileSystem.children(of: folder).isEmpty { try? fileManager.removeItem(at: folder) }
        }
        SecretsLog.purged(files: removed)
        return entries
    }

    /// "Free the space now": right after a tool command ran, permanently deletes the copies
    /// Domovy kept for exactly these entries, nothing else. Their undo ends here.
    @discardableResult
    public func purgeKeptCopies(of entries: [UndoEntry]) throws -> PurgePlan {
        let ids = Set(entries.map(\.id))
        let plan = PurgePlan(items: try purgePlan([.toolCopy]).items.filter { ids.contains($0.entryID) })
        guard !plan.isEmpty else { return plan }
        try purge(plan)
        return plan
    }

    /// Inside this entry's own backup folder (`Undo/<entry id>/`).
    private func isBackup(_ url: URL, of entry: UndoEntry) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: undoLog.backupDirectory(for: entry)) else { return false }
        return !relative.isEmpty && !relative.split(separator: "/").contains("..")
    }

    private func isInQuarantine(_ url: URL) -> Bool {
        guard let relative = FileSystem.relativePath(of: url, under: quarantineDirectory) else { return false }
        return !relative.isEmpty && !relative.split(separator: "/").contains("..")
    }
}
