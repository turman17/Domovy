import AppKit
import DomovyCore
import Observation
import os
import ServiceManagement
import SwiftUI

/// The app's copy of `settings.json`. The Settings window writes through it; the file is read
/// again when Domovy becomes active, so an edit made in a text editor shows up on return.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings(storeRoot: AppEnvironment.storeRoot)

    private(set) var settings: DomovySettings
    /// Values in the file Domovy could not use (Settings > Advanced).
    private(set) var issues: [SettingsIssue] = []
    /// The last save failed.
    private(set) var saveError: String?
    /// Set when Settings asks the main window to show onboarding.
    var wantsOnboarding = false
    /// Set to open the Settings window on a pane (a notification's Review, the popover's rules line).
    var requestedPane: SettingsCategory?

    let store: SettingsStore
    /// Called after every change, from the window or from the file (set by DomovyApp).
    @ObservationIgnored var onChange: ((DomovySettings) -> Void)?
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?
    @ObservationIgnored private let logger = Logger(subsystem: "io.github.turman17.Domovy", category: "Settings")

    init(storeRoot: URL) {
        store = SettingsStore(storeRoot: storeRoot)
        let loaded = store.load()
        settings = loaded.settings
        issues = loaded.issues
        migrateDefaults()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Reads the file again; changes only what differs, so views do not redraw for nothing.
    func reload() {
        let loaded = store.load()
        if loaded.issues != issues { issues = loaded.issues }
        guard loaded.settings != settings else { return }
        settings = loaded.settings
        onChange?(settings)
    }

    /// Changes settings and writes the file.
    func update(_ change: (inout DomovySettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        save()
        onChange?(next)
    }

    func reset(_ key: DomovySettings.Key) {
        update { $0.reset(key) }
    }

    /// Every value back to its default; keys Domovy does not know stay.
    func resetAll() {
        update { settings in
            let unknown = settings.unknown
            settings = DomovySettings()
            settings.unknown = unknown
        }
    }

    /// A binding for one value, for controls.
    func binding<Value>(_ keyPath: WritableKeyPath<DomovySettings, Value>) -> Binding<Value> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    /// Writes the current values so the file exists for "Open settings.json".
    func ensureFile() {
        guard !FileManager.default.fileExists(atPath: store.file.path) else { return }
        save()
    }

    private func save() {
        do {
            try store.save(settings)
            saveError = nil
            // A broken file was kept as .bak and replaced: its issue is gone.
            issues = store.load().issues
        } catch {
            saveError = error.localizedDescription
            logger.error("Saving settings failed: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// The List / By Project choice used to live in UserDefaults: it moves into the file once.
    private func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: "sessionsLayout") else { return }
        defaults.removeObject(forKey: "sessionsLayout")
        if let layout = DomovySettings.SessionsLayout(rawValue: raw), layout != settings.sessionsLayout {
            update { $0.sessionsLayout = layout }
        }
    }
}

/// Applies the settings that change the app itself: Dock icon and login item.
@MainActor
enum AppPresence {
    /// Regular app with a Dock icon, or a menu bar accessory.
    static func apply(_ settings: DomovySettings) {
        let policy: NSApplication.ActivationPolicy = settings.effectiveShowsInDock ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // An accessory app loses focus when its Dock icon goes; keep the window in front.
        if policy == .accessory { NSApp.activate() }
    }

    static var opensAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Needs approval in System Settings > General > Login Items when macOS asks.
    static var loginItemNeedsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setOpensAtLogin(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// Opens the main window from anywhere (Dock reopen, Finder, Settings links). Set by the first
/// view that has an `openWindow` action.
@MainActor
enum MainWindow {
    static var openAction: OpenWindowAction?

    static func open() {
        openAction?(id: "main")
        NSApp.activate()
    }
}

/// Reopening Domovy (Dock icon, Finder, Spotlight) with no window open shows the main window,
/// so it stays reachable with the menu bar item hidden.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppPresence.apply(AppSettings.shared.settings) }
        #if DEBUG
        // `DOMOVY_APPEARANCE=dark` (or `light`) forces that appearance, for window captures.
        switch ProcessInfo.processInfo.environment["DOMOVY_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        #endif
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { MainWindow.open() } }
        return true
    }
}
