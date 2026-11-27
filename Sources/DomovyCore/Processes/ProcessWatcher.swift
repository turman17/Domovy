import Foundation

/// Samples agent processes over time: CPU between samples, a rolling memory history for the
/// growth hint, and which processes belonged to an agent (so they are recognised once their
/// agent is gone). Kept only while a screen or command watches; nothing is written to disk.
public actor ProcessWatcher {
    let source: any ProcessSource
    let sessions: ProcessSessionResolver?
    let now: @Sendable () -> Date
    private var previousCPU: [ProcessKey: UInt64] = [:]
    private var previousAt: Date?
    private var history: MemoryHistory
    private var remembered: [ProcessKey: AgentKind] = [:]
    private var herdr: HerdrShellCache?

    public init(
        source: any ProcessSource = LibprocProcessSource(),
        sessions: ProcessSessionResolver?,
        herdr: HerdrClient? = nil,
        policy: GrowthPolicy = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.sessions = sessions
        self.now = now
        self.herdr = herdr.map(HerdrShellCache.init(client:))
        history = MemoryHistory(policy: policy)
    }

    /// A new report, or `nil` when the process list could not be read.
    public func refresh() -> ProcessReport? {
        guard let processes = source.snapshot() else { return nil }
        let date = now()
        let elapsed = previousAt.map { date.timeIntervalSince($0) } ?? 0
        history.record(Dictionary(processes.compactMap { p in p.footprintBytes.map { (p.key, $0) } }, uniquingKeysWith: { a, _ in a }), at: date)
        let output = ProcessAnalyzer(source: source, sessions: sessions).analyze(.init(
            processes: processes, previousCPU: previousCPU, elapsed: elapsed, history: history, remembered: remembered, herdr: herdr?.map(for: processes), now: date
        ))
        let alive = Set(processes.map(\.key))
        remembered = remembered.filter { alive.contains($0.key) }.merging(output.members) { _, new in new }
        previousCPU = Dictionary(processes.compactMap { p in p.cpuNanos.map { (p.key, $0) } }, uniquingKeysWith: { a, _ in a })
        previousAt = date
        return output.report
    }

    /// Two samples `interval` apart, so CPU shares are filled in (for `domo ps`).
    public func sampled(over interval: TimeInterval = 1) async -> ProcessReport? {
        _ = refresh()
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        return refresh()
    }

    /// Forgets the history, e.g. when the screen is hidden for a while.
    public func reset() {
        previousCPU = [:]
        previousAt = nil
        history = MemoryHistory(policy: history.policy)
    }
}
