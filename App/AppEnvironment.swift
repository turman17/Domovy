import DomovyCore
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

    /// Debug only: `DOMOVY_DISK_ANCHOR=local-models` scrolls the Disk screen there at launch.
    static var startDiskAnchor: String? {
        #if DEBUG
        if let anchor = ProcessInfo.processInfo.environment["DOMOVY_DISK_ANCHOR"], !anchor.isEmpty { return anchor }
        #endif
        return nil
    }

    /// Debug only: `DOMOVY_SELECT=<session id>` selects that session at launch.
    static var startSelection: String? {
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["DOMOVY_SELECT"], !id.isEmpty { return id }
        #endif
        return nil
    }

    /// Debug only: `DOMOVY_OPEN_CLEANUP=<cleanup id>` opens that cleanup's sheet on the Disk
    /// screen; model ids (comma separated) or `unused-models` open the model removal sheet.
    static var startCleanupRaw: String? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["DOMOVY_OPEN_CLEANUP"], !raw.isEmpty { return raw }
        #endif
        return nil
    }

    /// Debug only: `DOMOVY_OPEN_PROCESS_ACTION=quit:<pid>` (or `freeze:<pid>`) opens that
    /// confirmation sheet on the Processes screen. It never runs the action.
    static var startProcessAction: (action: String, pid: Int32)? {
        #if DEBUG
        if let raw = ProcessInfo.processInfo.environment["DOMOVY_OPEN_PROCESS_ACTION"] {
            let parts = raw.split(separator: ":")
            if parts.count == 2, let pid = Int32(parts[1]) { return (String(parts[0]), pid) }
        }
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
