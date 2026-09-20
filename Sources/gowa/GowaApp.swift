import SwiftUI

@main
struct GowaApp: App {
    var body: some Scene {
        WindowGroup("Gowa") {
            ContentView()
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
    }
}
