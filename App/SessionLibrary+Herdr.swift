import DomovyCore
import Foundation

/// Herdr: which pane a session's agent runs in, asked again right before a plan is shown.
extension SessionLibrary {
    var herdrClient: HerdrClient {
        HerdrClient.at(home: AppEnvironment.home, isCustomHome: AppEnvironment.isDevHome)
    }

    /// The pane a session runs in, from the last reload.
    func herdrPlacement(of session: Session) -> HerdrPlacement? {
        herdr.placement(of: session)
    }

    /// Fresh state for a plan (the CLI runs off the main actor); also kept for the inspector.
    func currentHerdr() async -> HerdrState {
        let client = herdrClient
        guard client.mayBeRunning else { return .empty }
        let state = await Task.detached { client.state() }.value ?? .empty
        herdr = state
        return state
    }
}
