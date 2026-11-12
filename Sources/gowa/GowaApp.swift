import SwiftUI

/// Entry point: dispatches between the headless CLI (`gowa run`, `gowa list`) and the
/// GUI app.
@main
struct GowaEntry {
    static func main() async {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "run" {
            await CLIMode.run(Array(arguments.dropFirst(2)))
            return
        }
        if arguments.count > 1, arguments[1] == "list" {
            await CLIMode.list(Array(arguments.dropFirst(2)))
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
            AppearanceCommands()
            CommandGroup(after: .textEditing) {
                Button("Find in Response") { app.beginFindInResponse() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(app.draft == nil)
            }
            CommandGroup(before: .newItem) {
                Button("Go to…") { app.showingPalette = true }
                    .keyboardShortcut("k")
                Button("Go to Request…") { app.showingPalette = true }
                    .keyboardShortcut("p")
                Divider()
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

struct AppearanceCommands: Commands {
    @AppStorage(Theme.glassKey) private var glass = true
    @AppStorage(Theme.ligaturesKey) private var ligatures = true
    @AppStorage(Theme.appearanceKey) private var appearance = Theme.Appearance.system.rawValue

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Picker("Appearance", selection: $appearance) {
                ForEach(Theme.Appearance.allCases) { option in
                    Text(option.title).tag(option.rawValue)
                }
            }
            Toggle("Glass Window", isOn: $glass)
            Toggle("Code Ligatures", isOn: $ligatures)
            Divider()
        }
    }
}
