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

enum SidebarSelection: Hashable {
    case section(SidebarItem)
    case agent(AgentKind)
}

struct ContentView: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(\.undoManager) private var undoManager
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
                SessionsView(agentFilter: agentFilter, search: search)
            } else if selection == .section(.disk) {
                DiskView(onOpenSessions: { selection = .agent($0) })
            } else if case .section(let item) = selection {
                ContentUnavailableView(item.rawValue, systemImage: item.symbol, description: Text("Not built yet."))
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search")
        .onAppear {
            library.undoManager = undoManager
            openRequestedSection()
        }
        .onChange(of: library.requestedSection) { _, _ in openRequestedSection() }
        .onChange(of: undoManager) { _, manager in library.undoManager = manager }
    }

    /// The menu bar popover asks for a section ("Open Disk").
    private func openRequestedSection() {
        guard let section = library.requestedSection else { return }
        selection = .section(section)
        library.requestedSection = nil
    }
}
