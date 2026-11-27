import AppKit
import DomovyCore
import SwiftUI

/// First-launch welcome: what Domovy reads, what it never does, optional Full Disk Access,
/// then the tour over the main window (TourController), which ends with Connect Agents. Shown
/// once; Domovy > Welcome to Domovy… opens it again.
struct OnboardingView: View {
    private enum Page: Int, CaseIterable {
        case reads, promises, fullDiskAccess
    }

    /// The last page's "Take the Tour"; the tour starts when the sheet is gone.
    var onTour: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var page: Page = .reads

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch page {
            case .reads: ReadsPage()
            case .promises: PromisesPage()
            case .fullDiskAccess: FullDiskAccessPage()
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 600, height: 520, alignment: .topLeading)
    }

    private var footer: some View {
        HStack {
            Text("Step \(page.rawValue + 1) of \(Page.allCases.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Escape skips from any page, like a sheet's Cancel.
            Button("Skip") { dismiss() }
                .keyboardShortcut(.cancelAction)
            if page != .reads {
                Button("Back") { move(-1) }
            }
            if page == .fullDiskAccess {
                Button("Take the Tour") {
                    onTour()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            } else {
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func move(_ step: Int) {
        if let next = Page(rawValue: page.rawValue + step) { page = next }
    }
}

// MARK: Pages

private struct ReadsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Domovy")
                        .font(.title2.weight(.semibold))
                    Text("Domovy keeps the house in order after your AI coding agents: it lists their sessions, archives them, and gives disk space back when you ask.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("What Domovy reads")
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                OnboardingItem(symbol: "folder", title: "Agent folders in your home",
                               detail: "~/.claude, ~/.codex, ~/.gemini, ~/.cursor, ~/.copilot, ~/.config/opencode and the like")
                OnboardingItem(symbol: "macwindow", title: "Agent app data",
                               detail: "~/Library/Application Support/Claude, Cursor, Code, Zed, Kiro and others")
                OnboardingItem(symbol: "cpu", title: "Local model stores",
                               detail: "~/.ollama, ~/.lmstudio, ~/.cache/huggingface")
                OnboardingItem(symbol: "waveform.path.ecg", title: "Running agent processes and their open files",
                               detail: "Only to tell which sessions are live, so Domovy leaves them alone")
            }
            Text("Transcripts are read only to show and search them on this Mac. Agents Domovy knows: \(knownAgents).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var knownAgents: String {
        AgentKind.allCases.map(\.displayName).formatted(.list(type: .and))
    }
}

private struct PromisesPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("What Domovy never does")
                    .font(.title2.weight(.semibold))
                Text("Every change is shown to you as a plan first, with each file it touches. Nothing happens until you confirm.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                OnboardingItem(symbol: "wifi.slash", title: "No network",
                               detail: "Domovy never connects to the internet. Your sessions stay on this Mac.")
                OnboardingItem(symbol: "eye.slash", title: "No telemetry or analytics",
                               detail: "Nothing about you or your work is collected or sent anywhere.")
                OnboardingItem(symbol: "arrow.uturn.backward", title: "No permanent delete by default",
                               detail: "Removed files go to the Trash or to Domovy\u{2019}s quarantine folder, and \u{2318}Z puts them back.")
                OnboardingItem(symbol: "bolt.slash", title: "Never touches a live session",
                               detail: "If an agent is still using a session, or Domovy is unsure, it refuses and says why.")
                OnboardingItem(symbol: "gearshape.2", title: "Never removes what an agent needs to run",
                               detail: "Settings, sign-ins, plugins, skills and memory are always kept.")
            }
        }
    }
}

private struct FullDiskAccessPage: View {
    @State private var status: FullDiskAccess.Status = FullDiskAccess.status()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Full Disk Access (optional)")
                    .font(.title2.weight(.semibold))
                Text("Domovy works without it. Most agents keep their files in your home folder, which Domovy can already read. A few keep data where macOS guards every app\u{2019}s privacy, such as Warp\u{2019}s app group. With Full Disk Access, Domovy can measure those too. It still only reads them, and nothing leaves this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            statusLabel
                .padding(.vertical, 4)
            HStack {
                Button("Open System Settings") {
                    if let url = FullDiskAccess.settingsURL { NSWorkspace.shared.open(url) }
                }
                Button("Check Again") { status = FullDiskAccess.status() }
            }
            Text("In System Settings, choose Privacy & Security > Full Disk Access and turn on Domovy. macOS may ask you to quit and reopen it. You can change this at any time.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            status = FullDiskAccess.status()
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch status {
        case .granted:
            Label("Full Disk Access is on.", systemImage: "checkmark.circle")
                .foregroundStyle(.tint)
        case .denied:
            Label("Full Disk Access is off. Domovy will note the few places it cannot measure.", systemImage: "lock")
                .foregroundStyle(.secondary)
        case .unknown:
            Label("Domovy could not tell whether Full Disk Access is on.", systemImage: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct OnboardingItem: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.tint)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(detail.hasPrefix("~") ? .callout.monospaced() : .callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Launch

extension AppEnvironment {
    /// Onboarding shows once, on the first launch against the real home. A dev home skips it
    /// unless `DOMOVY_ONBOARDING=1` (Debug builds) asks, which shows it on every launch.
    static func showsOnboardingAtLaunch(alreadyShown: Bool) -> Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DOMOVY_ONBOARDING"] == "1" { return true }
        #endif
        return !alreadyShown && !isDevHome
    }
}
