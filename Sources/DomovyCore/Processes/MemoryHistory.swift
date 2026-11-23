import Foundation

/// When memory growth counts as a likely leak: `bytes` within `interval`. Shorter histories
/// are judged at the same rate once they cover `minimumObservation`.
public struct GrowthPolicy: Hashable, Sendable {
    public var bytes: Int64
    public var interval: TimeInterval
    public var minimumObservation: TimeInterval

    public init(bytes: Int64 = 500_000_000, interval: TimeInterval = 600, minimumObservation: TimeInterval = 120) {
        self.bytes = bytes
        self.interval = interval
        self.minimumObservation = minimumObservation
    }

    public static let standard = GrowthPolicy()
}

/// A small rolling history of each process's memory, kept only while someone watches.
struct MemoryHistory: Sendable {
    struct Point: Sendable {
        let date: Date
        let bytes: Int64
    }

    let policy: GrowthPolicy
    private(set) var points: [ProcessKey: [Point]] = [:]

    init(policy: GrowthPolicy) {
        self.policy = policy
    }

    /// Adds the samples and forgets processes that are gone and points older than the window.
    mutating func record(_ samples: [ProcessKey: Int64], at date: Date) {
        var next: [ProcessKey: [Point]] = [:]
        for (key, bytes) in samples {
            var list = points[key] ?? []
            list.append(Point(date: date, bytes: bytes))
            list.removeAll { date.timeIntervalSince($0.date) > policy.interval }
            next[key] = list
        }
        points = next
    }

    /// Growth from the oldest kept point to the newest, when the history is long enough.
    func growth(of key: ProcessKey) -> (bytes: Int64, interval: TimeInterval)? {
        guard let list = points[key], let first = list.first, let last = list.last else { return nil }
        let span = last.date.timeIntervalSince(first.date)
        guard span >= policy.minimumObservation else { return nil }
        return (last.bytes - first.bytes, span)
    }

    /// Grew at least the policy's rate over what was observed.
    func isGrowing(_ key: ProcessKey) -> Bool {
        guard let growth = growth(of: key), growth.bytes > 0 else { return false }
        let allowed = Double(policy.bytes) * min(1, growth.interval / policy.interval)
        return Double(growth.bytes) >= allowed
    }
}
