import DomovyCore
import Foundation
import Observation

/// Agent processes for the Processes screen and the menu bar. Samples only while someone looks:
/// the screen refreshes every 2 seconds while visible, the popover once when it opens. Actions
/// are planned and confirmed in a sheet, never run on their own.
@MainActor
@Observable
final class ProcessMonitor {
    private(set) var report: ProcessReport = .empty
    /// The process list could not be read.
    private(set) var isUnavailable = false
    private(set) var lastRefresh: Date?
    /// The toolbar's pause button: the list stays as it is.
    var isPaused = false

    static let interval: Duration = .seconds(2)

    private let watcher: ProcessWatcher
    private let controller: ProcessController

    init(home: URL, storeRoot: URL) {
        watcher = ProcessWatcher(sessions: ProcessSessionResolver(home: home),
                                 herdr: HerdrClient.at(home: home, isCustomHome: AppEnvironment.isDevHome))
        controller = ProcessController(log: ProcessActionLog(storeRoot: storeRoot))
    }

    func refresh() async {
        let watcher = self.watcher
        let next = await watcher.refresh()
        // Observers are told about every assignment, equal or not: assign only what changed,
        // so the sidebar and the menu bar do not redraw on every sample.
        if isUnavailable != (next == nil) { isUnavailable = next == nil }
        if let next, next.groups != report.groups || next.orphans != report.orphans {
            report = next
            if orphanCount != next.orphanCount { orphanCount = next.orphanCount }
        }
        lastRefresh = Date()
    }

    /// For the popover: one sample unless the screen refreshed a moment ago.
    func refreshIfStale() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < 5 { return }
        await refresh()
    }

    /// Refreshes every `interval` until the calling task is cancelled (the screen disappears).
    func watch() async {
        while !Task.isCancelled {
            if !isPaused { await refresh() }
            try? await Task.sleep(for: Self.interval)
        }
    }

    func plan(_ action: ProcessAction, pid: Int32) throws -> ProcessActionPlan {
        try controller.plan(action, pid: pid, in: report)
    }

    func forceQuitPlan(after result: ProcessActionResult, of quit: ProcessActionPlan) -> ProcessActionPlan {
        controller.forceQuitPlan(after: result, of: quit)
    }

    func execute(_ plan: ProcessActionPlan) async throws -> ProcessActionResult {
        let controller = self.controller
        let result = try await Task.detached { try await controller.execute(plan) }.value
        await refresh()
        return result
    }

    // MARK: Menu bar

    /// Stored, so the sidebar badge only redraws when the count changes.
    private(set) var orphanCount = 0
    var orphanBytes: Int64 { report.orphanBytes }
    /// Likely MCP servers whose memory keeps growing, largest first.
    var growingServers: [ProcessNode] {
        report.growing.filter { $0.kind == .mcpServer }.sorted { ($0.footprintBytes ?? 0) > ($1.footprintBytes ?? 0) }
    }
    var needsAttention: Bool { orphanCount > 0 || !growingServers.isEmpty }
}
