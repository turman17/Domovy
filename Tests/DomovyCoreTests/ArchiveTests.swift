import DomovyCore
import Foundation
import Testing

/// Archive runs real APFS compression on a temp copy of the fixture home (the test temp
/// folder is on the APFS data volume). Nothing here touches the real home.
@Suite("Archive")
struct ArchiveTests {
    typealias IDs = FixtureHome.ClaudeCode

    static let project = "-Users-dev-code-orbit-api"
    static var transcriptPath: String { "projects/\(project)/\(IDs.idle).jsonl" }
    static var toolResultPath: String { "projects/\(project)/\(IDs.idle)/tool-results/r9big.txt" }

    /// The committed fixtures are tiny; ditto skips files of 16 KiB or less. Grow the idle
    /// session's transcript and add a large tool result, keeping the transcript's mtime.
    private func bulkyFixture() throws -> FixtureHome {
        let fixture = try FixtureHome()
        try fixture.appendSyntheticLines(to: Self.transcriptPath, kilobytes: 400)
        try fixture.appendSyntheticLines(to: Self.toolResultPath, kilobytes: 300)
        try fixture.appendSyntheticLines(to: "projects/\(Self.project)/memory/notes.md", kilobytes: 64)
        return fixture
    }

    @Test("plan lists only bulky session files, with sizes and an estimate, never protected paths")
    func planContents() async throws {
        let fixture = try bulkyFixture()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: adapter.session(matching: IDs.idle))

        #expect(plan.action == .archive)
        #expect(plan.destination == nil)
        #expect(plan.moves.isEmpty && plan.indexEdits.isEmpty)
        #expect(!plan.liveCheck.isLive)
        let files = Set(plan.compressions.map { FileSystem_relative($0.file, fixture.claudeDirectory) })
        #expect(files == [Self.transcriptPath, Self.toolResultPath])
        for item in plan.compressions {
            #expect(item.sizeBytes > 16 * 1024)
            #expect(item.estimatedBytes > 0 && item.estimatedBytes < item.sizeBytes / 2)
            #expect(item.modificationTime != nil)
        }
        #expect(plan.estimatedBytesAfter < plan.totalBytes)
        #expect(plan.summary.hasPrefix("Compresses 2 files ("))
        #expect(plan.summary.contains("Claude Code can still resume it. You can undo this."))

        let protected = ["memory", "plugins", "skills", "settings.json", "history.jsonl", "session-env", "security"]
        for item in plan.compressions {
            let parts = FileSystem_relative(item.file, fixture.claudeDirectory).split(separator: "/")
            for name in protected { #expect(!parts.contains(Substring(name))) }
        }
        let decoded = try JSONDecoder().decode(Plan.self, from: JSONEncoder().encode(plan))
        #expect(decoded == plan)
    }

    @Test("execute compresses in place, keeps bytes, mtimes and permissions; undo reverses it")
    func roundTrip() async throws {
        let fixture = try bulkyFixture()
        let adapter = fixture.adapter()
        let session = try await adapter.session(matching: IDs.idle)
        let plan = try await adapter.archivePlan(for: session)

        let paths = [Self.transcriptPath, Self.toolResultPath]
        let before = try paths.map { try fixture.snapshot($0) }
        let parentBefore = try fixture.snapshot("projects/\(Self.project)")
        let historyBefore = try fixture.snapshot("history.jsonl")

        let executor = fixture.executor()
        let entry = try executor.execute(plan)
        #expect(entry.action == .archive)
        #expect(entry.compressed.count == 2)
        #expect(entry.failure == nil)

        for (path, old) in zip(paths, before) {
            let now = try fixture.snapshot(path)
            #expect(now.isCompressed, "\(path) should be compressed")
            #expect(now.contents == old.contents)
            #expect(now.mtime == old.mtime, "mtime must survive to the nanosecond")
            #expect(now.mode == old.mode)
            #expect(now.allocated < old.allocated / 2, "\(path): \(old.allocated) -> \(now.allocated) bytes on disk")
        }
        #expect(try fixture.snapshot("projects/\(Self.project)").mtime == parentBefore.mtime)
        #expect(try fixture.snapshot("history.jsonl") == historyBefore)
        #expect(!fixture.leftoverStagingFolders())

        let listed = try #require(try await adapter.sessions().first { $0.id == IDs.idle })
        #expect(listed.status == .archived)
        #expect(listed.isArchived)
        #expect(listed.lastActive == session.lastActive)
        #expect(try await adapter.archivePlan(for: listed).isEmpty)

        let undone = try executor.undoLatestBatch()
        #expect(undone.count == 1 && undone[0].isUndone)
        for (path, old) in zip(paths, before) {
            let now = try fixture.snapshot(path)
            #expect(!now.isCompressed)
            #expect(now.contents == old.contents)
            #expect(now.mtime == old.mtime)
            #expect(now.mode == old.mode)
        }
        #expect(try fixture.snapshot("projects/\(Self.project)").mtime == parentBefore.mtime)
        #expect(try await adapter.sessions().first { $0.id == IDs.idle }?.status == .idle)
        #expect(try executor.undoLog.latestPending() == nil)
    }

    @Test("appending to a compressed transcript works and decompresses it (PLAN §11)")
    func appendAfterCompression() async throws {
        let fixture = try bulkyFixture()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: adapter.session(matching: IDs.idle))
        _ = try fixture.executor().execute(plan)
        let compressed = try fixture.snapshot(Self.transcriptPath)
        #expect(compressed.isCompressed)

        let line = Data("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"resumed later\"}}\n".utf8)
        let handle = try FileHandle(forWritingTo: fixture.claudeDirectory.appendingPathComponent(Self.transcriptPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.close()

        let after = try fixture.snapshot(Self.transcriptPath)
        #expect(after.contents == compressed.contents + line)
        #expect(!after.isCompressed, "APFS decompresses a compressed file on write")
        let listed = try await adapter.sessions().first { $0.id == IDs.idle }
        #expect(listed?.status == .idle)

        // Undo leaves the rewritten transcript alone and still decompresses the rest.
        let undone = try fixture.executor().undoLatestBatch()
        #expect(undone.first?.isUndone == true)
        #expect(try fixture.snapshot(Self.transcriptPath).contents == after.contents)
        #expect(!(try fixture.snapshot(Self.toolResultPath).isCompressed))
    }

    @Test("a file written after planning is left alone")
    func changedSincePlan() async throws {
        let fixture = try bulkyFixture()
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: adapter.session(matching: IDs.idle))
        try fixture.appendSyntheticLines(to: Self.toolResultPath, kilobytes: 1, keepModificationTime: false)

        let entry = try fixture.executor().execute(plan)
        #expect(entry.compressed.map { FileSystem_relative($0.file, fixture.claudeDirectory) } == [Self.transcriptPath])
        #expect(!(try fixture.snapshot(Self.toolResultPath).isCompressed))
    }

    @Test("refuses live sessions")
    func refusesLive() async throws {
        let fixture = try FixtureHome()
        try fixture.appendSyntheticLines(to: "projects/\(Self.project)/\(IDs.live).jsonl", kilobytes: 64)
        let adapter = fixture.adapter()
        let plan = try await adapter.archivePlan(for: adapter.session(matching: IDs.live))
        #expect(plan.liveCheck.isLive)
        #expect(plan.summary.hasPrefix("This session is live"))

        let executor = fixture.executor()
        #expect(throws: ExecutorError.self) { try executor.execute(plan) }
        #expect(throws: ExecutorError.self) { try executor.execute([plan]) }
        #expect(!(try fixture.snapshot("projects/\(Self.project)/\(IDs.live).jsonl").isCompressed))
        #expect(try executor.undoLog.entries().isEmpty)
    }

    @Test("a batch is undone as one")
    func batch() async throws {
        let fixture = try bulkyFixture()
        let expiringPath = "projects/-Users-dev-code-landing-site/\(IDs.expiring).jsonl"
        try fixture.appendSyntheticLines(to: expiringPath, kilobytes: 64)
        let adapter = fixture.adapter()
        let plans = [
            try await adapter.archivePlan(for: adapter.session(matching: IDs.idle)),
            try await adapter.archivePlan(for: adapter.session(matching: IDs.expiring)),
        ]
        let executor = fixture.executor()
        let entries = try executor.execute(plans)
        #expect(entries.count == 2)
        #expect(entries[0].batchID != nil && entries[0].batchID == entries[1].batchID)

        // Compression keeps the mtime, so an expiring session stays expiring.
        let expiring = try await adapter.sessions().first { $0.id == IDs.expiring }
        #expect(expiring?.status == .expiring)
        #expect(expiring?.isArchived == true)

        let undone = try executor.undoLatestBatch()
        #expect(undone.count == 2)
        #expect(!(try fixture.snapshot(expiringPath).isCompressed))
        #expect(!(try fixture.snapshot(Self.transcriptPath).isCompressed))
    }

    @Test("undo entries written before archive existed still decode")
    func legacyUndoEntry() throws {
        let json = """
        {"agent":"claudeCode","createdAt":"2026-11-20T10:00:00Z","destination":"trash","id":"6E0F3D2B-6C4E-4C8A-9F5B-1D2E3F405162",
         "indexRestores":[],"moved":[],"planID":"7E0F3D2B-6C4E-4C8A-9F5B-1D2E3F405162","sessionID":"aaaaaaaa-1111-4111-8111-111111111111"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(UndoEntry.self, from: Data(json.utf8))
        #expect(entry.action == .delete)
        #expect(entry.compressed.isEmpty)
        #expect(entry.batchID == nil)
        #expect(entry.destination == .trash)
    }
}

/// What the archive must keep: bytes, nanosecond mtime, mode. Plus the compression state.
struct FileSnapshot: Equatable {
    let contents: Data
    let mtime: timespec
    let mode: mode_t
    let allocated: Int64
    let isCompressed: Bool

    static func == (a: FileSnapshot, b: FileSnapshot) -> Bool {
        a.contents == b.contents && a.mtime.tv_sec == b.mtime.tv_sec && a.mtime.tv_nsec == b.mtime.tv_nsec
            && a.mode == b.mode && a.isCompressed == b.isCompressed
    }
}

extension timespec: @retroactive Equatable {
    public static func == (a: timespec, b: timespec) -> Bool { a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec }
}

extension FixtureHome {
    func snapshot(_ relative: String) throws -> FileSnapshot {
        let url = claudeDirectory.appendingPathComponent(relative)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        return FileSnapshot(
            contents: isDirectory ? Data() : try Data(contentsOf: url),
            mtime: info.st_mtimespec,
            mode: info.st_mode,
            allocated: Int64(info.st_blocks) * 512,
            isCompressed: info.st_flags & UInt32(UF_COMPRESSED) != 0
        )
    }

    /// Appends synthetic, compressible JSONL to a file (creating it), by default keeping its mtime.
    func appendSyntheticLines(to relative: String, kilobytes: Int, keepModificationTime: Bool = true) throws {
        let url = claudeDirectory.appendingPathComponent(relative)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = fm.fileExists(atPath: url.path)
        var info = stat()
        let hadTime = existed && lstat(url.path, &info) == 0
        if !existed { fm.createFile(atPath: url.path, contents: nil) }

        var text = ""
        var n = 0
        while text.utf8.count < kilobytes * 1024 {
            text += "{\"type\":\"tool_result\",\"n\":\(n),\"content\":\"synthetic build output: compiled module \(n % 40) without warnings\"}\n"
            n += 1
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
        if keepModificationTime, hadTime {
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), info.st_mtimespec]
            guard utimensat(AT_FDCWD, url.path, &times, 0) == 0 else { throw POSIXError(.EIO) }
        }
    }

    /// True if an archive left a `.domovy-*` staging folder anywhere in the fixture.
    func leftoverStagingFolders() -> Bool {
        let enumerator = FileManager.default.enumerator(atPath: claudeDirectory.path)
        while let path = enumerator?.nextObject() as? String {
            if (path as NSString).lastPathComponent.hasPrefix(".domovy-") { return true }
        }
        return false
    }
}
