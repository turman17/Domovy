import DomovyCore
import SwiftUI

enum SidebarItem: String, Hashable, CaseIterable, Identifiable {
    case sessions = "Sessions"
    case disk = "Disk"
    case processes = "Processes"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .sessions: "bubble.left.and.text.bubble.right"
        case .disk: "internaldrive"
        case .processes: "cpu"
        }
    }
}

extension SidebarItem {
    init(_ section: DomovySettings.LaunchSection) {
        switch section {
        case .sessions: self = .sessions
        case .disk: self = .disk
        case .processes: self = .processes
        }
    }
}

enum SidebarSelection: Hashable {
    case section(SidebarItem)
    case agent(AgentKind)
}

struct ContentView: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    @State private var selection: SidebarSelection? = AppEnvironment.startSection
    @State private var search = ""

    private var showsSessions: Bool {
        switch selection {
        case .section(.sessions), .agent, nil: true
        case .section: false
        }
    }

    private var agentFilter: AgentKind? {
        if case .agent(let kind) = selection { return kind }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            if showsSessions {
                SessionsView(agentFilter: agentFilter, search: search, clearSearch: { search = "" })
            } else if selection == .section(.disk) {
                DiskView(onOpenSessions: { selection = .agent($0) })
            } else if selection == .section(.processes) {
                ProcessesView(search: search)
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .onAppear {
            library.undoManager = undoManager
            MainWindow.openAction = openWindow
            openRequestedSection()
        }
        .onChange(of: library.requestedSection) { _, _ in openRequestedSection() }
        // A search belongs to the list it was typed in: another sidebar item starts unfiltered.
        .onChange(of: selection) { search = "" }
        .onChange(of: library.requestedSearch) { _, requested in
            guard let requested else { return }
            search = requested
            library.requestedSearch = nil
        }
        .onChange(of: undoManager) { _, manager in library.undoManager = manager }
        #if DEBUG
        .onChange(of: PerfDriver.shared.sidebarRequest) { _, request in if let request { selection = request.selection } }
        .onChange(of: PerfDriver.shared.searchRequest) { _, request in if let request { search = request.text } }
        #endif
    }

    /// The menu bar popover asks for a section ("Open Disk").
    private func openRequestedSection() {
        guard let section = library.requestedSection else { return }
        selection = .section(section)
        library.requestedSection = nil
    }
}
