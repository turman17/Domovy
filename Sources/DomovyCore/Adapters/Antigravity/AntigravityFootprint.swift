import Foundation

extension AntigravityAdapter {
    /// Read-only breakdown of each Antigravity store. Sizes come from file metadata; the
    /// conversation databases are never opened here.
    public func footprint() async throws -> Footprint {
        let stores = stores
        guard let first = stores.first else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: stores.count == 1 ? first.root : root)
        for store in stores {
            let prefix = stores.count == 1 ? "" : "\(store.name): "
            let count = store.catalog().files.count
            builder.add(prefix + "Settings, sign-in, tools", AntigravityStore.protectedEntries.sorted().map { store.root.appendingPathComponent($0) },
                        reveal: store.root, .keep, "Antigravity needs these to run. Domovy never removes them.")
            builder.add(prefix + "Conversations", [store.conversations, store.brain, store.annotations], reveal: store.root, .consequences,
                        "\(count) \(count == 1 ? "conversation" : "conversations") and their brain folders. Antigravity keeps the newest \(Self.conversationCap). Delete or archive them in Sessions.",
                        guidance: .manageInSessions)
            builder.add(prefix + "Implicit memory", store.root.appendingPathComponent("implicit", isDirectory: true), .consequences,
                        "What Antigravity learned across conversations. It starts over without it.")
            builder.add(prefix + "Prompt history", store.history, .consequences, "Typed prompts for the prompt history.")
            builder.add(prefix + "Logs and crash reports",
                        ["log", "crashes", "cli.log"].map { store.root.appendingPathComponent($0) }, reveal: store.root, .safe,
                        "Diagnostic logs. Antigravity writes new ones; remove them while it is quit.")
            builder.add(prefix + "Other", builder.unclaimedChildren(of: store.root), reveal: store.root, .keep,
                        "Scratch files and state Domovy does not manage yet. Left alone.")
        }
        return builder.build()
    }
}
