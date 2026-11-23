import DomovyCore
import SwiftUI

@main
struct DomovyApp: App {
    @State private var library = SessionLibrary(home: AppEnvironment.home, storeRoot: AppEnvironment.storeRoot)

    var body: some Scene {
        Window("Domovy", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 820, minHeight: 560)
                .task { await library.reload() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo Move to Trash") {
                    Task { try? await library.undo() }
                }
                .keyboardShortcut("z")
                .disabled(!library.canUndo)
            }
            CommandGroup(after: .toolbar) {
                Button("Reload Sessions") { Task { await library.reload() } }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(library)
        } label: {
            Label(library.totalFootprintBytes.formatted(.byteCount(style: .file)), systemImage: "house")
        }
        .menuBarExtraStyle(.window)
    }
}
