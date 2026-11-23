import Foundation

/// Where Domovy looks for agent data.
///
/// Debug runs from Xcode or `make run` set `DOMOVY_ROOT` to `.devhome`, a fake home copied
/// from the test fixtures, so development never reads or changes the real home folder.
enum AppEnvironment {
    static var home: URL {
        if let root = ProcessInfo.processInfo.environment["DOMOVY_ROOT"], !root.isEmpty {
            return URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// Domovy's own folder: quarantine and undo log. Same place the CLI uses, so a fixture
    /// home stays self-contained.
    static var storeRoot: URL {
        home.appendingPathComponent("Library/Application Support/Domovy", isDirectory: true)
    }

    /// Debug only: `DOMOVY_START_SECTION=disk` opens the window on that section, so a window
    /// capture can show it without clicking.
    static var startSection: SidebarSelection {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["DOMOVY_START_SECTION"],
           let item = SidebarItem.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() }) {
            return .section(item)
        }
        #endif
        return .section(.sessions)
    }

    /// Debug only: `DOMOVY_SELECT=<session id>` selects that session at launch.
    static var startSelection: String? {
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["DOMOVY_SELECT"], !id.isEmpty { return id }
        #endif
        return nil
    }

    /// Debug only: `DOMOVY_SCAN_SECRETS=1` runs the secret scan over every session after launch.
    static var scansSecretsAtLaunch: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["DOMOVY_SCAN_SECRETS"] == "1"
        #else
        return false
        #endif
    }

    static var isDevHome: Bool {
        ProcessInfo.processInfo.environment["DOMOVY_ROOT"]?.isEmpty == false
    }
}
