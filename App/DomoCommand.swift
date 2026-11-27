import AppKit
import DomovyCore
import SwiftUI

/// The `domo` command: the copy inside Domovy.app, and "Install 'domo' Command in PATH" (a link
/// to it, like VS Code's `code`). Connect registers the most stable path: the link or a
/// Homebrew `domo` when there is one, else the app bundle.
@MainActor
enum DomoCommand {
    static var bundled: URL? { MCPRegistration.bundledDomo() }

    /// Asks the login shell for PATH, so call it off the main thread.
    nonisolated static func link() -> DomoCommandLink {
        DomoCommandLink(home: AppEnvironment.home, isCustomHome: AppEnvironment.isDevHome)
    }

    /// The executable agents should run.
    nonisolated static func registered(_ status: DomoCommandLink.Status) -> URL? {
        if case .linked(let url, _) = status { return MCPRegistration.installedDomo(linked: url) }
        return MCPRegistration.installedDomo()
    }

    nonisolated static func status() async -> DomoCommandLink.Status {
        await Task.detached { link().status() }.value
    }

    /// Installs the link and tells the user where it went. Returns the new status.
    @discardableResult
    static func install() async -> DomoCommandLink.Status {
        let bundled = bundled
        let outcome: Result<DomoCommandLink.Target, any Error> = await Task.detached {
            Result { try link().install(bundled: bundled) }
        }.value
        let alert = NSAlert()
        switch outcome {
        case .success(let target):
            alert.messageText = "The domo command is installed"
            var text = "\(DomovyTools.display(target.link, home: AppEnvironment.home)) now points at the domo inside Domovy. Try `domo ls` in a new Terminal window."
            if let advice = target.pathAdvice {
                text = "\(DomovyTools.display(target.link, home: AppEnvironment.home)) points at the domo inside Domovy, but that folder is not on your PATH yet. Add this line to ~/.zshrc, then open a new Terminal window:\n\n\(advice)"
                if let bundled { text += "\n\nOr put the link in /usr/local/bin with an administrator password:\n\n\(DomoCommandLink.manualCommand(bundled: bundled))" }
            }
            alert.informativeText = text
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "The domo command was not installed"
            alert.informativeText = (error as? DomoCommandLink.LinkError)?.message ?? error.localizedDescription
        }
        alert.runModal()
        return await status()
    }

    @discardableResult
    static func uninstall() async -> DomoCommandLink.Status {
        let outcome: Result<[URL], any Error> = await Task.detached { Result { try link().uninstall() } }.value
        let alert = NSAlert()
        switch outcome {
        case .success(let removed) where removed.isEmpty:
            alert.messageText = "There is no domo link of Domovy's to remove"
            alert.informativeText = "A domo installed by Homebrew stays; remove it with `brew uninstall domo`."
        case .success(let removed):
            alert.messageText = "The domo command is uninstalled"
            alert.informativeText = "Removed the link \(removed.map { DomovyTools.display($0, home: AppEnvironment.home) }.joined(separator: ", ")). Agents connected through it need Connect Agents again."
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "The domo command was not uninstalled"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
        return await status()
    }

    static func describe(_ status: DomoCommandLink.Status?) -> String {
        switch status {
        case .linked(let url, true): "Installed: \(DomovyTools.display(url, home: AppEnvironment.home))"
        case .linked(let url, false): "Linked at \(DomovyTools.display(url, home: AppEnvironment.home)), which is not on PATH"
        case .otherOnPath(let url): "On PATH: \(DomovyTools.display(url, home: AppEnvironment.home))"
        case .notInstalled: "Not on PATH"
        case nil: "Checking\u{2026}"
        }
    }
}

/// Install / Uninstall buttons for the `domo` command, with its state. Used in Settings and the
/// Connect sheet.
struct DomoCommandControls: View {
    @State private var status: DomoCommandLink.Status?
    var onChange: ((DomoCommandLink.Status) -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(DomoCommand.describe(status))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            switch status {
            case .linked:
                Button("Uninstall \u{2018}domo\u{2019} Command") { Task { update(await DomoCommand.uninstall()) } }
            case .notInstalled:
                Button("Install \u{2018}domo\u{2019} Command\u{2026}") { Task { update(await DomoCommand.install()) } }
                    .disabled(DomoCommand.bundled == nil)
            case .otherOnPath, nil:
                EmptyView()
            }
        }
        .task { update(await DomoCommand.status()) }
    }

    private func update(_ new: DomoCommandLink.Status) {
        status = new
        onChange?(new)
    }
}

/// App menu items: Install / Uninstall 'domo' Command in PATH.
struct DomoCommandMenuItems: View {
    var body: some View {
        Button("Install \u{2018}domo\u{2019} Command in PATH") { Task { await DomoCommand.install() } }
            .disabled(DomoCommand.bundled == nil)
        Button("Uninstall \u{2018}domo\u{2019} Command") { Task { await DomoCommand.uninstall() } }
    }
}
