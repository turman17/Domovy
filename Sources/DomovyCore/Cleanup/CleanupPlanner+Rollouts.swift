import Foundation

/// "Compress…" for Codex rollouts over 100 MB: APFS compression in place, the same path an
/// archive takes without the codex CLI. Codex reads the files as before and can resume them.
extension CleanupPlanner {
    func largeRolloutsPlan() async throws -> CleanupPlan {
        let layout = CodexLayout(root: codexRoot)
        let files = layout.rolloutFiles()
        let large = (files.active + files.archived).filter { DiskUsage.measure($0).logical > CodexAdapter.largeRolloutBytes }
        guard !large.isEmpty else { throw CleanupError.notFound(.codexLargeRollouts) }

        let check = await openFileCheck(large)
        var compressions: [FileCompression] = []
        var excluded: [CleanupExclusion] = []
        for file in large {
            let size = APFSCompression.allocatedBytes(of: file)
            func exclude(_ reason: String) { excluded.append(CleanupExclusion(url: file, sizeBytes: size, reason: reason)) }
            if file.lastPathComponent.hasSuffix(".zst") {
                exclude("Already compressed by Codex (zstd).")
            } else if !APFSCompression.isRegularFile(file) {
                exclude("Not a regular file.")
            } else if APFSCompression.isCompressed(file) {
                exclude("Already compressed in place.")
            } else if let holder = check.holders.first(where: { !matchOpenPaths([$0], against: [file]).isEmpty }) {
                exclude("\(holder.processName) (pid \(holder.pid)) has it open.")
            } else {
                let name = CodexLayout.rolloutName(file.lastPathComponent)
                compressions.append(FileCompression(
                    file: file,
                    sizeBytes: size,
                    estimatedBytes: APFSCompression.estimatedCompressedBytes(of: file),
                    modificationTime: FileSystem.modificationTime(of: file),
                    note: name?.segmentID == nil ? "Rollout over 100 MB" : "Rollout segment over 100 MB"
                ))
            }
        }
        // Only an unreadable check blocks; a file in use is left out on its own.
        let blocked = check.status == .unavailable
        let plan = Plan(
            agent: .codex,
            sessionID: CleanupID.codexLargeRollouts.rawValue,
            action: .archive,
            destination: nil,
            moves: [],
            indexEdits: [],
            compressions: compressions,
            remarks: [
                "Codex reads compressed rollouts as before; a session it writes to again is decompressed on the fly. Modification dates stay as they are.",
            ],
            liveCheck: LiveCheckResult(isLive: blocked, reasons: blocked ? check.reasons : [], checkedSignals: ["open file handles"], openHandles: check.status),
            scope: self.scope
        )
        return CleanupPlan(cleanup: .codexLargeRollouts, plan: plan, excluded: excluded, hasConsequences: false)
    }
}
