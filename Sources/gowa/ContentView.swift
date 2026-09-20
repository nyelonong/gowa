import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        NavigationSplitView {
            CollectionSidebar(app: app)
        } detail: {
            VStack(spacing: 0) {
                if app.environments.count > 1 || (app.environments.count == 1 && app.document != nil) {
                    environmentBar
                }
                RequestEditor(app: app)
                if app.draft != nil {
                    Divider()
                    ResponseArea(app: app)
                }
            }
        }
        .navigationTitle("Gowa")
        .frame(minWidth: 960, minHeight: 620)
    }

    private var environmentBar: some View {
        @Bindable var app = app

        return HStack(spacing: 10) {
            if !app.environments.isEmpty {
                Picker("Environment", selection: Binding(
                    get: { app.activeEnvironment ?? "" },
                    set: { app.activeEnvironment = $0.isEmpty ? nil : $0 }
                )) {
                    Text("No environment").tag("")
                    ForEach(app.environments) { env in
                        Text(env.name).tag(env.name)
                    }
                }
                .labelsHidden()
                .frame(width: 200)

                Image(systemName: "curlybraces")
                    .foregroundStyle(.tertiary)
                    .help("Variables of the active environment substitute {{name}} placeholders")
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
