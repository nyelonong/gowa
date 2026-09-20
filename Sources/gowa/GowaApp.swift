import SwiftUI

@main
struct GowaApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup("Gowa") {
            ContentView()
                .environment(app)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Collection") { app.newCollection() }
                    .keyboardShortcut("n")
                Button("Open Collection…") { app.openCollectionPanel() }
                    .keyboardShortcut("o")
                Button("Save Collection") { app.saveCollection() }
                    .keyboardShortcut("s")
                    .disabled(app.document == nil)
                Button("Save Collection As…") { app.saveCollectionAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(app.document == nil)
            }
        }
    }
}
