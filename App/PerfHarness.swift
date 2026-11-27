#if DEBUG
import AppKit
import DomovyCore
import Foundation
import Observation
import SwiftUI

/// Debug only (`DOMOVY_PERF=1`): drives the app's state by itself and logs `PERF|name|ms`
/// (median of 3) with NSLog. A step is timed until the main thread is free again: after the
/// state change, a 1 ms sleep only resumes once SwiftUI's update has been flushed.
/// Never confirms a sheet and never calls an execute, archive or delete API.
/// Hooks live in ContentView, SessionsView, TranscriptView and the two plan sheets, all `#if DEBUG`.
@MainActor
@Observable
final class PerfDriver {
    static let shared = PerfDriver()

    struct SessionsCommand: Equatable {
        enum Kind: Equatable {
            case select([String])
            case sort(column: String, ascending: Bool)
            case openDelete([String])
            case openArchive([String])
            case openInfo
            case dismissSheets
        }
        let id: Int
        let kind: Kind
    }
    struct SidebarRequest: Equatable { let id: Int; let selection: SidebarSelection }
    struct SearchRequest: Equatable { let id: Int; let text: String }

    // Observed by the views.
    var sessionsCommand: SessionsCommand?
    var sidebarRequest: SidebarRequest?
    var searchRequest: SearchRequest?

    // Written by the views.
    var transcriptLoaded: String?
    var planShown = false
    var rowIDs: () -> [String] = { [] }

    @ObservationIgnored private var counter = 0
    @ObservationIgnored private var results: [(String, [Double])] = []
    @ObservationIgnored private var library: SessionLibrary!
    @ObservationIgnored private var processes: ProcessMonitor!

    // MARK: Hooks the driver pushes

    private func send(_ kind: SessionsCommand.Kind) { counter += 1; sessionsCommand = .init(id: counter, kind: kind) }
    private func sidebar(_ s: SidebarSelection) { counter += 1; sidebarRequest = .init(id: counter, selection: s) }
    private func search(_ t: String) { counter += 1; searchRequest = .init(id: counter, text: t) }

    // MARK: Timing

    private func settle() async {
        var quiet = 0
        let clock = ContinuousClock()
        while quiet < 2 {
            let t = clock.now
            try? await Task.sleep(for: .milliseconds(1))
            if clock.now - t < .milliseconds(6) { quiet += 1 } else { quiet = 0 }
        }
    }

    private func wait(timeout: Double = 30, _ cond: () -> Bool) async {
        let clock = ContinuousClock()
        let start = clock.now
        while !cond(), clock.now - start < .seconds(timeout) { try? await Task.sleep(for: .milliseconds(1)) }
    }

    private func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func measure(_ name: String, runs: Int = 3, prep: (() async -> Void)? = nil, _ action: () async -> Void) async {
        var samples: [Double] = []
        for _ in 0..<runs {
            if let prep { await prep(); await settle() }
            let t = ContinuousClock.now
            await action()
            samples.append(ms(ContinuousClock.now - t))
        }
        record(name, samples)
    }

    private func record(_ name: String, _ samples: [Double]) {
        let sorted = samples.sorted()
        let median = sorted[sorted.count / 2]
        NSLog("PERFRUN|%@|%@", name, samples.map { String(format: "%.0f", $0) }.joined(separator: ","))
        NSLog("PERF|%@|%.0f", name, median)
    }

    // MARK: Script

    func run(library: SessionLibrary, processes: ProcessMonitor, launchMs: Double) async {
        self.library = library
        self.processes = processes
        record("launch.sessionsAndSizesReady", [launchMs])
        try? await Task.sleep(for: .seconds(2))
        await settle()

        let sessions = library.sessions
        NSLog("PERF|info.sessions|%d", sessions.count)
        let columns = ["title", "agent", "project", "lastActive", "size", "status"]

        // Sort, both directions. The table is rebuilt on every sort.
        for column in columns {
            for ascending in [true, false] {
                let other = !ascending
                await measure("sort.\(column).\(ascending ? "asc" : "desc")",
                              prep: { self.send(.sort(column: column, ascending: other)) }) {
                    self.send(.sort(column: column, ascending: ascending))
                    await self.settle()
                }
            }
        }
        send(.sort(column: "lastActive", ascending: false))
        await settle()

        // Selecting a row until its transcript is loaded.
        let ids = rowIDs()
        let normalPool = sessions.filter { $0.agent == .claudeCode && $0.memberCount == 1 }.sorted { $0.sizeBytes < $1.sizeBytes }
        let normal = normalPool.isEmpty ? nil : normalPool[normalPool.count / 2]
        let largest = sessions.filter { $0.memberCount == 1 }.max { $0.sizeBytes < $1.sizeBytes }
        for (label, session) in [("normal", normal), ("largest", largest)] {
            guard let session else { continue }
            NSLog("PERF|info.select.%@|%@ %lld bytes", label, session.agent.displayName, session.sizeBytes)
            await measure("select.\(label)Transcript",
                          prep: { self.send(.select([])); self.transcriptLoaded = nil }) {
                self.transcriptLoaded = nil
                self.send(.select([session.id]))
                await self.wait { self.transcriptLoaded == session.id }
                await self.settle()
            }
        }

        // 20 consecutive rows, one per tick, like holding an arrow key.
        let first20 = Array(ids.prefix(20))
        await measure("select.step20rows(total)", prep: { self.send(.select([])) }) {
            for id in first20 {
                self.send(.select([id]))
                try? await Task.sleep(for: .milliseconds(1))
            }
            await self.settle()
        }

        // Search.
        for (label, text) in [("match", "refact"), ("nomatch", "qqqqqq")] {
            await measure("search.set.\(label)", prep: { self.search("") }) {
                self.search(text)
                await self.settle()
            }
            await measure("search.clear.\(label)", prep: { self.search(text) }) {
                self.search("")
                await self.settle()
            }
        }

        // Select all.
        await measure("selectAll", prep: { self.send(.select([])) }) {
            self.send(.select(ids))
            await self.settle()
        }
        await measure("selectNone(after all)", prep: { self.send(.select(ids)) }) {
            self.send(.select([]))
            await self.settle()
        }

        // Get Info.
        if let normal {
            await measure("getInfo.open", prep: { self.send(.select([normal.id])); self.send(.dismissSheets) }) {
                self.send(.openInfo)
                await self.settle()
            }
            send(.dismissSheets)
            await settle()
        }

        // Plan sheets: only until the plan is shown, then dismissed. Never confirmed.
        let archivable = sessions.filter { $0.agent == .claudeCode && $0.status == .idle && !$0.isArchived && $0.canArchive && $0.memberCount == 1 }
        let deletable = sessions.filter { $0.status == .idle && $0.memberCount == 1 }
        for n in [1, 20] {
            let a = Array((archivable.count >= n ? archivable : deletable).prefix(n)).map(\.id)
            let d = Array(deletable.prefix(n)).map(\.id)
            await measure("sheet.archive.\(n)", prep: { self.send(.dismissSheets); self.planShown = false }) {
                self.planShown = false
                self.send(.openArchive(a))
                await self.wait { self.planShown }
                await self.settle()
            }
            send(.dismissSheets); await settle()
            await measure("sheet.trash.\(n)", prep: { self.send(.dismissSheets); self.planShown = false }) {
                self.planShown = false
                self.send(.openDelete(d))
                await self.wait { self.planShown }
                await self.settle()
            }
            send(.dismissSheets); await settle()
        }

        // Sidebar: agents, then the other screens.
        for agent in library.agentsPresent {
            await measure("sidebar.agent.\(agent.displayName)", prep: { self.sidebar(.section(.sessions)) }) {
                self.sidebar(.agent(agent))
                await self.settle()
            }
        }
        await measure("sidebar.sessions(all)", prep: { self.sidebar(.section(.disk)) }) {
            self.sidebar(.section(.sessions))
            await self.settle()
        }
        await measure("screen.disk", prep: { self.sidebar(.section(.sessions)) }) {
            self.sidebar(.section(.disk))
            await self.settle()
        }
        await measure("screen.processes(first rows)", prep: { self.sidebar(.section(.sessions)) }) {
            let before = self.processes.lastRefresh
            self.sidebar(.section(.processes))
            await self.wait { self.processes.lastRefresh != before }
            await self.settle()
        }
        await measure("sidebar.sessions(from processes)", prep: { self.sidebar(.section(.processes)) }) {
            self.sidebar(.section(.sessions))
            await self.settle()
        }

        NSLog("PERF|done|0")
        NSApp.terminate(nil)
    }

    /// Process start to now, in ms (kern.proc info), for the launch figure.
    static func millisecondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return (Date().timeIntervalSince1970 - started) * 1000
    }
}

#endif
