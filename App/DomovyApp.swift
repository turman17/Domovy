import DomovyCore
import SwiftUI

@main
struct DomovyApp: App {
    @State private var library = SessionLibrary(home: AppEnvironment.home, storeRoot: AppEnvironment.storeRoot, isCustomHome: AppEnvironment.isDevHome)

    var body: some Scene {
        Window("Domovy", id: "main") {
            ContentView()
                .environment(library)
                .frame(minWidth: 820, minHeight: 560)
                .task { await library.reload() }
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            // Undo/Redo stay the system items: Domovy actions are registered with the window's
            // UndoManager, so ⌘Z reads "Undo Move to Trash" / "Undo Archive" outside text fields.
            CommandGroup(after: .toolbar) {
                Button("Reload Sessions") { Task { await library.reload() } }
                    .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarView()
                .environment(library)
        } label: {
            Label {
                Text(library.totalFootprintBytes.formatted(.byteCount(style: .file)))
            } icon: {
                Image("MenuBarGlyph")
            }
            .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}
