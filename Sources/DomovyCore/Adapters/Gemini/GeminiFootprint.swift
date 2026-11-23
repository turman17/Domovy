import Foundation

extension GeminiAdapter {
    /// Read-only breakdown of Gemini CLI's part of `~/.gemini`. Antigravity's folders are left
    /// to its own footprint. Sizes come from file metadata; nothing is opened.
    public func footprint() async throws -> Footprint {
        guard layout.probe() != .notInstalled else { throw AdapterError.notInstalled(kind) }
        var builder = FootprintBuilder(agent: kind, root: root)
        builder.claim(["antigravity", "antigravity-cli"].map { root.appendingPathComponent($0, isDirectory: true) })

        let protected = GeminiLayout.protectedRootEntries.subtracting(["antigravity", "antigravity-cli"]).sorted().map { root.appendingPathComponent($0) }
        builder.add("Settings, sign-in, extensions", protected, reveal: root, .keep,
                    "Gemini CLI needs these to run. Domovy never removes them.")

        let projects = FileSystem.children(of: layout.tmp).filter(FileSystem.isDirectory)
        let chats = projects.flatMap { FileSystem.children(of: $0.appendingPathComponent("chats", isDirectory: true)) }
        let count = projects.reduce(0) { $0 + GeminiLayout.chatFiles(in: $1).count }
        builder.add("Chats", chats, reveal: layout.tmp, .consequences,
                    "\(count) \(count == 1 ? "chat" : "chats"). Delete or archive them one by one in Sessions.", guidance: .manageInSessions)
        builder.claim(projects.map { $0.appendingPathComponent("chats", isDirectory: true) })

        let companions = projects.flatMap { project in
            ["logs", "tool-outputs"].map { project.appendingPathComponent($0, isDirectory: true) }
                + FileSystem.children(of: project).filter { FileSystem.isDirectory($0) && !GeminiLayout.projectEntries.contains($0.lastPathComponent) }
        }
        builder.add("Activity logs and tool outputs", companions, reveal: layout.tmp, .consequences,
                    "Logs, tool outputs and plans of chats. They go with their chat.")
        builder.add("Checkpoints", projects.map { $0.appendingPathComponent("checkpoints", isDirectory: true) }, reveal: layout.tmp, .consequences,
                    "Chats saved with /chat save and /restore points. Remove them in Gemini CLI with /chat delete.")
        builder.add("Prompt logs", projects.map { $0.appendingPathComponent("logs.json") }, reveal: layout.tmp, .consequences,
                    "Typed prompts per project, for Gemini CLI's prompt history.")
        builder.add("File snapshot history", layout.history, .consequences,
                    "Shadow git repositories behind /restore, one per project. Needed to restore files edited in past chats.")
        // Each project's leftovers, then whatever else sits in tmp/ (never a project folder twice).
        let state = projects.flatMap { builder.unclaimedChildren(of: $0) }
        builder.claim(projects)
        builder.add("Project state", state + builder.unclaimedChildren(of: layout.tmp),
                    reveal: layout.tmp, .keep, "Project markers and state Domovy does not manage yet. Left alone.")
        builder.claim([layout.tmp])
        builder.add("Other", builder.unclaimedChildren(of: root), reveal: root, .keep,
                    "Caches and state Domovy does not manage yet. Left alone.")
        return builder.build()
    }
}
