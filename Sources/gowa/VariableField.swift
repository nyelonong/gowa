import SwiftUI

/// Variables visible to a field: what `{{name}}` resolves to at send time.
struct VariableScope: Equatable {
    var values: [String: String]
    var secretNames: Set<String> = []

    func isDefined(_ name: String) -> Bool {
        if name.hasPrefix("$") { return TemplateFunctions.isKnown(String(name.dropFirst()).components(separatedBy: "(").first ?? "") }
        return values[name] != nil
    }
}

struct VariableField: View {
    let placeholder: String
    @Binding var text: String
    var variables: VariableScope?
    var onSubmit: (() -> Void)?

    init(_ placeholder: String, text: Binding<String>, variables: VariableScope? = nil, onSubmit: (() -> Void)? = nil) {
        self.placeholder = placeholder
        self._text = text
        self.variables = variables
        self.onSubmit = onSubmit
    }

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(.callout, design: .monospaced))
            .onSubmit { onSubmit?() }
    }
}
