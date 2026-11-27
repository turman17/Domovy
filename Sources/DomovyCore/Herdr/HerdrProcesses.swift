import Foundation

/// Which pane each Herdr shell belongs to, for grouping agent processes by workspace and pane.
public struct HerdrProcessMap: Hashable, Sendable {
    /// Pane shell pid → where it sits.
    public var shells: [Int32: HerdrPlacement]

    public init(shells: [Int32: HerdrPlacement] = [:]) {
        self.shells = shells
    }

    /// The pane `pid` runs in: its own or its nearest ancestor's shell.
    func placement(of pid: Int32, table: [Int32: RawProcess]) -> HerdrPlacement? {
        var current: Int32? = pid
        var steps = 0
        while let next = current, next > 1, steps < 128 {
            if let placement = shells[next] { return placement }
            current = table[next]?.ppid
            steps += 1
        }
        return nil
    }

    /// A Herdr process (server or client), whose trees are never orphans: they still run in a pane.
    static func isHerdr(_ process: RawProcess) -> Bool {
        process.name == "herdr" || process.executablePath.map { ($0 as NSString).lastPathComponent == "herdr" } == true
    }
}

/// Keeps the pane → shell pid map between samples. Pane ids are never reused and a pane keeps
/// its shell, so each pane is asked once; panes that closed are dropped. The pane list itself
/// is asked again at most every `maxAge` seconds, so a screen sampling every 2 seconds does not
/// start three processes each time.
struct HerdrShellCache: Sendable {
    let client: HerdrClient
    var maxAge: TimeInterval = 5
    private var shellOfPane: [String: Int32] = [:]
    private var cached: (state: HerdrState, at: Date)?

    init(client: HerdrClient) {
        self.client = client
    }

    /// `nil` when no Herdr process runs, so the CLI is not even started.
    mutating func map(for processes: [RawProcess]) -> HerdrProcessMap? {
        guard processes.contains(where: HerdrProcessMap.isHerdr) else { return nil }
        let state: HerdrState
        if let cached, Date().timeIntervalSince(cached.at) < maxAge {
            state = cached.state
        } else {
            guard let fresh = client.state() else { return nil }
            cached = (fresh, Date())
            state = fresh
        }
        let table = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let live = Set(state.panes.map(\.id))
        shellOfPane = shellOfPane.filter { live.contains($0.key) }
        var shells: [Int32: HerdrPlacement] = [:]
        for pane in state.panes {
            if shellOfPane[pane.id] == nil, let pid = client.shellPID(ofPane: pane.id) { shellOfPane[pane.id] = pid }
            // Only a shell that still runs under a Herdr process counts; a reused pid does not.
            guard let pid = shellOfPane[pane.id], let shell = table[pid], let parent = table[shell.ppid], HerdrProcessMap.isHerdr(parent),
                  let placement = state.placement(ofPane: pane.id) else { continue }
            shells[pid] = placement
        }
        return HerdrProcessMap(shells: shells)
    }
}
