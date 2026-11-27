import DomovyCore
import SwiftUI

/// "Resume in Herdr" when Herdr runs, else "Resume in Terminal"; "Show in Herdr" for a live
/// session running in a Herdr pane. Used in the inspector and in context menus.
struct ResumeButtons: View {
    @Environment(SessionLibrary.self) private var library
    let session: Session

    var body: some View {
        if let placement = library.herdrPlacement(of: session) {
            Button("Show in Herdr", systemImage: "rectangle.split.2x1") {
                Task {
                    do { try await ResumeLauncher.showInHerdr(placement, client: library.herdrClient) }
                    catch { library.actionError = error.localizedDescription }
                }
            }
            .help("Bring Herdr forward on \(placement.title), where this session runs")
        } else if let plan = ResumeLauncher.herdrPlan(session, herdr: library.herdr) {
            Button("Resume in Herdr", systemImage: "rectangle.split.2x1") {
                Task {
                    do { try await ResumeLauncher.resumeInHerdr(session, plan: plan, client: library.herdrClient) }
                    catch { library.actionError = error.localizedDescription }
                }
            }
            .disabled(ResumeLauncher.unavailableReason(session) != nil)
            .help(ResumeLauncher.unavailableReason(session) ?? herdrHelp(plan))
        } else {
            let note = ResumeLauncher.unavailableReason(session)
            Button("Resume in Terminal", systemImage: "terminal") {
                do { try ResumeLauncher.resume(session) } catch { library.actionError = error.localizedDescription }
            }
            .disabled(note != nil)
            .help(note ?? "Open this session in \(session.agent.displayName), in its project folder")
        }
    }

    private func herdrHelp(_ plan: HerdrResume) -> String {
        let place = plan.workspaceID.flatMap { library.herdr.workspace($0)?.label }.map { "a new tab of \($0)" } ?? "a new Herdr workspace"
        return "Open this session in \(session.agent.displayName), in \(place)"
    }
}
