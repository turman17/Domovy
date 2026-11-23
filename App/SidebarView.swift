import DomovyCore
import SwiftUI

struct SidebarView: View {
    @Environment(SessionLibrary.self) private var library
    @Environment(ProcessMonitor.self) private var processes
    @Binding var selection: SidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Sessions", systemImage: SidebarItem.sessions.symbol)
                    .badge(library.sessions.count)
                    .tag(SidebarSelection.section(.sessions))
                Label("Disk", systemImage: SidebarItem.disk.symbol)
                    .badge(Text(library.totalFootprintBytes.formatted(.byteCount(style: .file))))
                    .tag(SidebarSelection.section(.disk))
                Label("Processes", systemImage: SidebarItem.processes.symbol)
                    .badge(processes.orphanCount > 0 ? Text("\(processes.orphanCount) orphaned") : nil)
                    .tag(SidebarSelection.section(.processes))
            }
            Section("Agents") {
                ForEach(library.agentsPresent, id: \.self) { agent in
                    Label {
                        Text(agent.displayName)
                    } icon: {
                        AgentGlyph(agent: agent)
                    }
                    .badge(library.count(for: agent))
                    .tag(SidebarSelection.agent(agent))
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            BreakdownBar(segments: library.footprintByAgent.map { ($0.agent.displayName, $0.bytes) })
            Text("\(library.totalFootprintBytes.formatted(.byteCount(style: .file))) used by AI agents")
                .font(.caption.weight(.semibold))
            Text(Greeting.line(needsAttention: library.needsAttention))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

/// One line of house-spirit warmth. Never in the way of the task.
enum Greeting {
    static func line(needsAttention: Bool, now: Date = Date()) -> String {
        let hour = Calendar.current.component(.hour, from: now)
        let time = hour < 12 ? "Morning" : hour < 18 ? "Afternoon" : "Evening"
        return needsAttention ? "\(time). A few things need attention." : "\(time). The house is in order."
    }
}
