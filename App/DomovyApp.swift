import DomovyCore
import SwiftUI

@main
struct DomovyApp: App {
    @Environment(\.openSettings) private var openSettings
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared
    @State private var library = SessionLibrary(home: AppEnvironment.home, storeRoot: AppEnvironment.storeRoot, isCustomHome: AppEnvironment.isDevHome)
    @State private var processes = ProcessMonitor(home: AppEnvironment.home, storeRoot: AppEnvironment.storeRoot)
    @State private var rules = RulesController(home: AppEnvironment.home, storeRoot: AppEnvironment.storeRoot, isCustomHome: AppEnvironment.isDevHome)
    @State private var showsConnect = false
    @State private var showsOnboarding = false
    /// Onboarding, then the tour, is shown once, on the first launch.
    @AppStorage("didShowOnboarding") private var didShowOnboarding = false
    @AppStorage(TourController.shownKey) private var didShowTour = false
    /// The welcome sheet hands over to the tour when it closes.
    @State private var toursAfterWelcome = false

    var body: some Scene {
        Window("Domovy", id: "main") {
            ContentView()
                .environment(library)
                .environment(processes)
                .environment(rules)
                .task { rules.attach(library) }
                .task { connectSettings() }
                .modifier(RulesWindowOpener(controller: rules))
                #if DEBUG
                .task {
                    // `DOMOVY_OPEN_SETTINGS=1` (or a pane, `=rules`) opens Settings at launch, for a window capture.
                    // `DOMOVY_OPEN_CONNECT=1` opens Connect Agents the same way.
                    if ProcessInfo.processInfo.environment["DOMOVY_OPEN_CONNECT"] == "1" { showsConnect = true }
                    guard ProcessInfo.processInfo.environment["DOMOVY_OPEN_SETTINGS"] != nil else { return }
                    try? await Task.sleep(for: .milliseconds(500))
                    openSettings()
                }
                #endif
                .onChange(of: settings.wantsOnboarding, initial: true) { _, wants in
                    guard wants else { return }
                    settings.wantsOnboarding = false
                    showsOnboarding = true
                }
                .frame(minWidth: 820, minHeight: 560)
                .sheet(isPresented: $showsConnect) { ConnectAgentsSheet() }
                .sheet(isPresented: $showsOnboarding, onDismiss: {
                    guard toursAfterWelcome else { return }
                    toursAfterWelcome = false
                    TourController.shared.request()
                }) {
                    OnboardingView(onTour: { toursAfterWelcome = true })
                }
                .modifier(TourHost(library: library, onConnect: { showsConnect = true }))
                .task {
                    if let step = AppEnvironment.startTourStep {
                        TourController.shared.request(from: step)
                    } else if AppEnvironment.showsOnboardingAtLaunch(alreadyShown: didShowOnboarding) {
                        didShowOnboarding = true
                        toursAfterWelcome = true
                        showsOnboarding = true
                    } else if AppEnvironment.showsOnboardingAtLaunch(alreadyShown: didShowTour) {
                        // Saw the welcome before the tour existed.
                        TourController.shared.request()
                    }
                    await library.reload()
                    if AppEnvironment.scansSecretsAtLaunch { library.scanSecrets(library.sessions) }
                    #if DEBUG
                    if AppEnvironment.perfEnabled {
                        await PerfDriver.shared.run(library: library, processes: processes, launchMs: PerfDriver.millisecondsSinceProcessStart())
                    }
                    #endif
                }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Welcome to Domovy\u{2026}") { showsOnboarding = true }
            }
            CommandGroup(after: .importExport) {
                ExportCommand()
            }
            CommandGroup(after: .help) {
                Button("Take the Tour") { TakeTour.start() }
                    .disabled(TourController.shared.isRunning)
            }
            CommandGroup(after: .appSettings) {
                Button("Connect Agents\u{2026}") { showsConnect = true }
                DomoCommandMenuItems()
            }
            // Undo/Redo stay the system items: Domovy actions are registered with the window's
            // UndoManager, so ⌘Z reads "Undo Move to Trash" / "Undo Archive" outside text fields.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Find\u{2026}") { SearchField.focus() }
                    .keyboardShortcut("f")
            }
            CommandMenu("Session") {
                SessionCommandMenuItems()
            }
            CommandGroup(after: .toolbar) {
                Button("Reload Sessions") { Task { await library.reload() } }
                    .keyboardShortcut("r")
                Button("Scan for Secrets") { library.scanSecrets(library.sessions) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("Rebuild Search Index") { library.transcriptSearch.rebuild() }
            }
        }

        Settings {
            SettingsView()
                .environment(library)
                .environment(processes)
                .environment(rules)
                .environment(settings)
                .task { rules.attach(library) }
                .task { connectSettings() }
        }

        MenuBarExtra(isInserted: menuBarItemShown) {
            MenuBarView()
                .environment(library)
                .environment(processes)
                .environment(rules)
                .task { rules.attach(library) }
        } label: {
            MenuBarLabel(library: library, display: settings.settings.menuBarDisplay)
                .modifier(RulesWindowOpener(controller: rules))
                .task { rules.attach(library) }
                .task { connectSettings() }
        }
        .menuBarExtraStyle(.window)
    }

    /// Settings > General > Menu bar item; the system sets it to false when the item is
    /// dragged out of the menu bar.
    private var menuBarItemShown: Binding<Bool> {
        Binding(
            get: { settings.settings.showsMenuBarItem },
            set: { shown in
                guard shown != settings.settings.showsMenuBarItem else { return }
                settings.update { $0.menuBarDisplay = shown ? .iconOnly : .hidden }
            }
        )
    }

    /// Settings changes reach the library, the rules and the Dock. Each apply does nothing
    /// when its part did not change, so every scene may connect.
    private func connectSettings() {
        let library = library, rules = rules
        settings.onChange = { new in
            AppPresence.apply(new)
            library.apply(new)
            rules.apply(new)
        }
    }
}

/// The menu bar item: the glyph, and the number Settings chose. Reads only that number, so
/// the item redraws only when it changes.
private struct MenuBarLabel: View {
    let library: SessionLibrary
    let display: DomovySettings.MenuBarDisplay

    var body: some View {
        if let text {
            Label {
                Text(text)
            } icon: {
                Image("MenuBarGlyph")
            }
            .labelStyle(.titleAndIcon)
        } else {
            Image("MenuBarGlyph")
                .accessibilityLabel("Domovy")
        }
    }

    private var text: String? {
        switch display {
        case .iconOnly, .hidden: nil
        case .totalSize: library.menuBarFigures.totalBytes.formatted(.byteCount(style: .file))
        case .reclaimableSize: library.menuBarFigures.safeBytes.formatted(.byteCount(style: .file))
        case .liveSessions: "\(library.menuBarFigures.liveSessions) live"
        }
    }
}

/// Session menu: the toolbar's actions with their shortcuts. Space and Delete in the list do
/// Quick Look and Move to Trash too.
private struct SessionCommandMenuItems: View {
    @FocusedValue(\.sessionCommands) private var commands

    var body: some View {
        Button("Quick Look") { commands?.quickLook?() }
            .keyboardShortcut("y")
            .disabled(commands?.quickLook == nil)
        Button("Get Info") { commands?.getInfo?() }
            .keyboardShortcut("i")
            .disabled(commands?.getInfo == nil)
        Divider()
        Button("Archive\u{2026}") { commands?.archive?() }
            .keyboardShortcut("a", modifiers: [.command, .option])
            .disabled(commands?.archive == nil)
        Button("Move to Trash\u{2026}") { commands?.delete?() }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(commands?.delete == nil)
    }
}

/// Edit > Find… (⌘F): the toolbar search field of the front window, or the first search field
/// inside it (Settings' sidebar). SwiftUI's `.searchable` has no focus binding on macOS 14.
@MainActor
enum SearchField {
    static func focus() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        for item in window.toolbar?.items ?? [] {
            if let search = item as? NSSearchToolbarItem {
                search.beginSearchInteraction()
                return
            }
            if let field = first(in: item.view) {
                window.makeFirstResponder(field)
                return
            }
        }
        if let field = first(in: window.contentView) { window.makeFirstResponder(field) }
    }

    private static func first(in view: NSView?) -> NSSearchField? {
        guard let view else { return nil }
        if let field = view as? NSSearchField { return field }
        for child in view.subviews {
            if let field = first(in: child) { return field }
        }
        return nil
    }
}

/// File > Export Transcript… for the selected sessions (⇧⌘E).
private struct ExportCommand: View {
    @FocusedValue(\.exportTranscripts) private var export

    var body: some View {
        Button("Export Transcript\u{2026}") { export?.perform() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(export == nil)
    }
}
