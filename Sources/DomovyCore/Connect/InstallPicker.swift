import Foundation

/// The `domo install` picker: one row per detected agent, all checked to start, with what
/// connecting it changes. Space toggles the row under the cursor, Enter applies the checked
/// ones. The terminal handling lives in the CLI; this is the state and the text, so it can be
/// tested without a terminal.
public struct InstallPicker: Sendable {
    public enum Key: Sendable, Hashable {
        case up, down, toggle, all, clear, apply, cancel
    }

    public enum Outcome: Sendable, Hashable {
        case apply([ConnectAgent])
        case cancel
    }

    /// Detected agents, in `ConnectAgent` order.
    public let rows: [AgentConnectPlan]
    public private(set) var selected: Set<ConnectAgent>
    public private(set) var cursor = 0

    public init(plan: ConnectPlan) {
        rows = plan.agents.filter { $0.state != .notDetected }
        selected = Set(rows.map(\.agent))
    }

    /// The checked agents, in row order. Without a terminal `domo install -y` applies these:
    /// every detected agent.
    public var chosen: [ConnectAgent] {
        rows.map(\.agent).filter(selected.contains)
    }

    /// Checked agents that will actually change.
    public var changing: [AgentConnectPlan] {
        rows.filter { selected.contains($0.agent) && $0.state == .willChange }
    }

    /// Handles one key; returns the outcome once the user applies or cancels.
    public mutating func handle(_ key: Key) -> Outcome? {
        switch key {
        case .up: cursor = rows.isEmpty ? 0 : (cursor + rows.count - 1) % rows.count
        case .down: cursor = rows.isEmpty ? 0 : (cursor + 1) % rows.count
        case .toggle:
            guard rows.indices.contains(cursor) else { break }
            let agent = rows[cursor].agent
            if selected.contains(agent) { selected.remove(agent) } else { selected.insert(agent) }
        case .all: selected = Set(rows.map(\.agent))
        case .clear: selected = []
        case .apply: return .apply(chosen)
        case .cancel: return .cancel
        }
        return nil
    }

    /// The key for bytes read from a terminal in raw mode, or `nil` to ignore them.
    public static func key(for bytes: [UInt8]) -> Key? {
        switch bytes {
        case [0x1B, 0x5B, 0x41], [0x6B]: .up // arrow up, k
        case [0x1B, 0x5B, 0x42], [0x6A]: .down // arrow down, j
        case [0x20]: .toggle
        case [0x61]: .all // a
        case [0x6E]: .clear // n
        case [0x0D], [0x0A]: .apply
        case [0x1B], [0x71], [0x03]: .cancel // esc, q, ctrl-c
        default: nil
        }
    }

    /// The picker as lines: a checkbox per agent, its state and what connecting it changes.
    public func lines(home: URL, highlight: Bool = true) -> [String] {
        var lines = ["Choose the agents to connect to Domovy (space toggles, a all, n none, enter applies, q cancels):", ""]
        for (index, item) in rows.enumerated() {
            let pointer = highlight && index == cursor ? ">" : " "
            let box = selected.contains(item.agent) ? "[x]" : "[ ]"
            lines.append("\(pointer) \(box) \(item.agent.displayName)  \(Self.stateText(item))")
            guard selected.contains(item.agent), item.state == .willChange else { continue }
            for step in item.steps { lines.append("        - \(step.description(home: home))") }
        }
        let count = changing.count
        lines.append("")
        lines.append(count == 0 ? "Nothing to change for the checked agents." : "Enter connects \(count) \(count == 1 ? "agent" : "agents"). Config files are backed up first; `domo disconnect` removes exactly what was added.")
        return lines
    }

    static func stateText(_ item: AgentConnectPlan) -> String {
        switch item.state {
        case .willChange: item.isConnected ? "update" : "connect"
        case .upToDate: "already connected"
        case .notDetected: "not found"
        case .refused(let reason): "can't connect now: \(reason)"
        }
    }
}
