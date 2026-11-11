import SwiftUI

struct CodeSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss
    @AppStorage("gowa.codegen.language") private var languageName = CodeGenerator.Language.curl.rawValue
    @State private var copied = false

    private var language: CodeGenerator.Language {
        CodeGenerator.Language(rawValue: languageName) ?? .curl
    }

    var body: some View {
        let result = app.effectiveRequestForCode()
        let request = try? result?.get()
        let code = request.map { CodeGenerator.generate($0.effective, language: language) } ?? ""
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Generate Code").font(.headline)
                Picker("Language", selection: $languageName) {
                    ForEach(CodeGenerator.Language.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                }
                .disabled(code.isEmpty)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            if let request {
                CodeViewer(text: code, runs: [], wraps: false)
                Divider()
                Label(request.note, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            } else {
                let message: String = if case .failure(let error) = result { error.localizedDescription } else { "Select a request first" }
                ContentUnavailableView("Can't build this request", systemImage: "chevron.left.forwardslash.chevron.right", description: Text(message))
            }
        }
        .frame(minWidth: 720, minHeight: 480)
        .onChange(of: languageName) { copied = false }
    }
}
