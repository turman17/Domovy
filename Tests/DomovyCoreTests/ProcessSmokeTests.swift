import Darwin
@testable import DomovyCore
import Foundation
import Testing

/// Real signals, but only to a process this test starts itself: a copy of `/bin/sleep` named
/// like an MCP server, left behind by a shell that exits, so launchd adopts it as an orphan.
@Suite("Processes (real)")
struct ProcessSmokeTests {
    @Test("finds its own orphaned child, freezes, resumes and quits it")
    func freezeResumeQuit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("domovy-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let binary = dir.appendingPathComponent("domovy-mcp-smoke")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: binary)
        // A copy of a macOS binary only runs outside /bin once signed again (ad hoc).
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["-s", "-", "-f", binary.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run()
        sign.waitUntilExit()
        try #require(sign.terminationStatus == 0)

        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "\"$0\" 60 >/dev/null 2>&1 </dev/null & echo $!", binary.path]
        shell.standardOutput = output
        try shell.run()
        shell.waitUntilExit()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        let source = LibprocProcessSource()
        // The forked shell becomes the copy once it has exec'd.
        var started = try #require(source.process(pid))
        for _ in 0..<40 where started.name != "domovy-mcp-smoke" {
            try await Task.sleep(nanoseconds: 25_000_000)
            started = try #require(source.process(pid))
        }
        defer {
            // Only ever the process started above, and only while it is still that process.
            if source.process(pid)?.startMicros == started.startMicros { kill(pid, SIGKILL) }
        }
        #expect(started.name == "domovy-mcp-smoke")

        // Reparenting to launchd happens as the shell exits; give it a moment.
        var report = ProcessReport.empty
        for _ in 0..<20 {
            report = try #require(await ProcessWatcher(source: source, sessions: nil).refresh())
            if report.orphans.contains(where: { $0.pid == pid }) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let orphan = try #require(report.orphans.first { $0.pid == pid })
        #expect(orphan.kind == .mcpServer && orphan.refusal == nil)

        let controller = ProcessController(source: source, log: nil)
        _ = try await controller.execute(try controller.plan(.freeze, pid: pid, in: report))
        #expect(source.process(pid)?.isStopped == true)
        let frozen = try #require(await ProcessWatcher(source: source, sessions: nil).refresh())
        _ = try await controller.execute(try controller.plan(.resume, pid: pid, in: frozen))
        #expect(source.process(pid)?.isStopped == false)

        let quit = try await controller.execute(try controller.plan(.quit, pid: pid, in: frozen))
        #expect(quit.signaled.map(\.pid) == [pid])
        #expect(quit.stillRunning.isEmpty)
        #expect(source.process(pid) == nil)
    }
}
