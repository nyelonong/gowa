import SwiftUI

/// Entry point: dispatches between the headless CLI (`gowa run …`) and the
/// GUI app.
@main
struct GowaEntry {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "run" {
            await CLIMode.run(Array(arguments.dropFirst(2)))
            return
        }
        if arguments.count > 1, arguments[1] == "--help" || arguments[1] == "-h" {
            CLIMode.printUsage()
            return
        }
        GowaApp.main()
    }
}

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
            CommandGroup(after: .textEditing) {
                Button("Find in Response") { app.beginFindInResponse() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(app.draft == nil)
            }
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
