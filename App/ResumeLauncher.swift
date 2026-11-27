import AppKit
import DomovyCore

/// "Resume in Terminal": writes the agent's own resume command into a temporary `.command`
/// file and opens it with the app that opens `.command` files (Terminal, or iTerm, Ghostty or
/// Warp when the user made it the default). No AppleScript. The file removes itself when it runs.
@MainActor
enum ResumeLauncher {
    /// The command, or why the button is disabled.
    static func availability(_ session: Session) -> Result<ResumeCommand, ResumeCommand.Unavailable> {
        ResumeCommand.resolve(for: session)
    }

    /// Help text for a disabled Resume item, `nil` when it can run.
    static func unavailableReason(_ session: Session) -> String? {
        if AppEnvironment.isDevHome { return "Not with the dev home: it would run the real agent." }
        if case .failure(let why) = availability(session) { return why.localizedDescription }
        return nil
    }

    static func resume(_ session: Session) throws {
        if AppEnvironment.isDevHome { throw LaunchError.devHome }
        let command = try availability(session).get()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Domovy", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("Resume \(session.agent.displayName) \(UUID().uuidString.prefix(8)).command")
        try Data(command.script.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        let terminal = NSWorkspace.shared.urlForApplication(toOpen: file)
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        guard let terminal else { throw LaunchError.noTerminal }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: configuration) { _, error in
            guard error != nil else { return }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Herdr

    /// Herdr runs and can start this agent: Resume opens a tab there instead of a terminal.
    static func herdrPlan(_ session: Session, herdr: HerdrState) -> HerdrResume? {
        guard !herdr.workspaces.isEmpty, case .success(let command) = availability(session) else { return nil }
        return HerdrResume.plan(for: command, sessionID: session.id, in: herdr)
    }

    /// A new tab in the workspace that works in the project folder (else a new workspace),
    /// then `herdr agent start` with the agent's own resume arguments. If no pane could be
    /// made, the terminal takes over.
    static func resumeInHerdr(_ session: Session, plan: HerdrResume, client: HerdrClient) async throws {
        if AppEnvironment.isDevHome { throw LaunchError.devHome }
        let pane = await Task.detached { client.json(plan.paneArguments).flatMap(HerdrState.rootPaneID(fromCreated:)) }.value
        guard let pane else { return try resume(session) }
        // Herdr waits until the agent is ready for input, up to its 30-second default.
        let started = await Task.detached { client.json(plan.startArguments(pane: pane), timeout: 40) != nil }.value
        guard started else { throw LaunchError.herdrStart(pane) }
        activateHerdr()
    }

    /// `herdr agent focus <pane>` for a live session, then brings Herdr forward.
    static func showInHerdr(_ placement: HerdrPlacement, client: HerdrClient) async throws {
        let done = await Task.detached { client.json(HerdrResume.focusArguments(pane: placement.paneID)) != nil }.value
        guard done else { throw LaunchError.herdrFocus(placement.title) }
        activateHerdr()
    }

    private static func activateHerdr() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "dev.herdr.app").first?.activate()
    }

    enum LaunchError: LocalizedError {
        case devHome
        case noTerminal
        case herdrStart(String)
        case herdrFocus(String)

        var errorDescription: String? {
            switch self {
            case .devHome: "Resume is off with the dev home: it would run the real agent."
            case .noTerminal: "Domovy found no terminal app to open the resume command in."
            case .herdrStart(let pane): "Herdr opened pane \(pane) but the agent did not start there. Look at that pane in Herdr."
            case .herdrFocus(let title): "Herdr could not show \(title). It may have closed."
            }
        }
    }
}
