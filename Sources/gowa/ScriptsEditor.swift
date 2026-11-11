import SwiftUI

/// Pre-request, post-response, and tests scripts for a request, folder, or collection.
struct ScriptsEditor: View {
    let scripts: [OCScript]
    let onChange: ([OCScript]) -> Void
    @State private var phase = Phase.before

    enum Phase: String, CaseIterable, Identifiable {
        case before = "before-request"
        case after = "after-response"
        case tests = "tests"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .before: "Pre-request"
            case .after: "Post-response"
            case .tests: "Tests"
            }
        }

        var help: String {
            switch self {
            case .before: "Runs before sending. req.setHeader(name, value), req.setUrl(url), req.setBody(obj), bru.setVar(name, value), bru.getEnvVar(name)."
            case .after: "Runs after the response. res.status, res.getBody(), res('$.data.id'), res.getHeader(name), bru.setVar(name, value), bru.setEnvVar(name, value)."
            case .tests: "test(\"status is 200\", () => expect(res.status).to.equal(200)). Also: .to.eql, .to.be.a('string'), .to.have.property, .to.include, .to.be.above. console.log shows in Console."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TabStrip(tabs: Phase.allCases, selection: $phase, title: \.title) { phase in
                    code(phase).isEmpty ? 0 : 1
                }
                Spacer()
            }
            Text(phase.help)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            CodeEditor(
                text: Binding(
                    get: { code(phase) },
                    set: { text in
                        var next = scripts.filter { $0.type != phase.rawValue }
                        if !text.isEmpty { next.append(OCScript(type: phase.rawValue, code: text)) }
                        onChange(next)
                    }
                ),
                highlightsJSON: false
            )
            .id(phase)
            .background(Theme.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.hairline))
            .frame(minHeight: 160, maxHeight: .infinity)
        }
    }

    private func code(_ phase: Phase) -> String {
        scripts.first { $0.type == phase.rawValue }?.code ?? ""
    }
}
