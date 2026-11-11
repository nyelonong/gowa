import SwiftUI

struct GrpcView: View {
    let app: AppState
    let draft: OCGrpcSnapshot
    @State private var tab = Tab.message

    enum Tab: String, CaseIterable, Identifiable {
        case message = "Message"
        case metadata = "Metadata"
        case auth = "Auth"
        case schema = "Schema"
        case docs = "Docs"
        var id: String { rawValue }
    }

    private var session: GrpcSession { app.grpc }

    var body: some View {
        VSplitView {
            editor
                .frame(minHeight: 280)
            GrpcResultView(session: session)
                .frame(minHeight: 180)
                .layoutPriority(1)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: Binding(get: { draft.name }, set: { name in change { $0.name = name } }))
                    .font(.title3.weight(.semibold))
                    .textFieldStyle(.plain)
                    .background(InitialFocusClearer())
                    .accessibilityLabel("gRPC request name")
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Text("gRPC")
                            .font(.system(.callout, design: .monospaced).weight(.bold))
                            .foregroundStyle(.indigo)
                        Divider().frame(height: 16)
                        VariableField(
                            "localhost:50051 or grpcs://api.example.com",
                            text: Binding(get: { draft.url }, set: { url in change { $0.url = url } }),
                            variables: app.variableScope,
                            fontSize: 13,
                            onSubmit: { app.invokeGrpc() }
                        )
                        .accessibilityLabel("gRPC server address")
                        methodMenu
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: Theme.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.hairline))

                    if session.calling {
                        ProgressView().controlSize(.small)
                        Button("Stop") { app.cancelGrpc() }
                            .controlSize(.large)
                    } else {
                        Button {
                            app.invokeGrpc()
                        } label: {
                            Label("Invoke", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(app.activeEnvironmentColor)
                        .controlSize(.large)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.method.isEmpty && session.schema == nil && draft.url.isEmpty)
                    }
                }
                if let error = session.error, !session.calling {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            TabStrip(tabs: Tab.allCases, selection: $tab, title: \.rawValue) { tab in
                switch tab {
                case .metadata: draft.metadata.filter { !$0.disabled }.count
                case .docs: (draft.docs ?? "").isEmpty ? 0 : 1
                default: 0
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            Divider()

            Group {
                switch tab {
                case .message: composer
                case .metadata:
                    ScrollView {
                        KeyValueTable(rows: draft.metadata.map(\.kvRow), noun: "entry", variables: app.variableScope) { edit in
                            change { $0.metadata.apply(edit) }
                        }
                        .padding(16)
                    }
                case .auth:
                    ScrollView {
                        AuthEditor(auth: draft.authKind, variables: app.variableScope, tokenActions: app.tokenActions(at: app.selectedRequestPath)) { auth in
                            change { $0.authKind = auth }
                        }
                        .padding(16)
                    }
                case .schema: schemaSettings
                case .docs:
                    DocsEditor(text: draft.docs ?? "") { text in change { $0.docs = text.isEmpty ? nil : text } }
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var methodMenu: some View {
        Menu {
            if let schema = session.schema {
                ForEach(Array(Dictionary(grouping: schema.methods, by: \.service).keys.sorted()), id: \.self) { service in
                    Section(service) {
                        ForEach(schema.methods.filter { $0.service == service }, id: \.self) { method in
                            Button("\(method.name)  ·  \(method.kind)") { choose(method) }
                        }
                    }
                }
                Divider()
            }
            Button(session.loadingSchema ? "Loading…" : "Load Methods") { app.loadGrpcSchema() }
                .disabled(session.loadingSchema)
        } label: {
            Text(draft.method.isEmpty ? "Choose method" : (draft.method.split(separator: "/").last.map(String.init) ?? draft.method))
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        .help(draft.method.isEmpty ? "Load the server's methods" : draft.method)
        .accessibilityLabel("gRPC method")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(draft.method.isEmpty ? "No method chosen" : draft.method)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(draft.methodType)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.indigo.opacity(0.12), in: Capsule())
                Spacer()
                if let schema = session.schema, let method = schema.method(draft.method) {
                    Button("Example Message") {
                        let template = ProtoCodec(schema: schema).template(for: method.input)
                        change { $0.message = JSONPath.render([method.clientStreaming ? [template] : template]) }
                    }
                    .controlSize(.small)
                }
                Button("Format") {
                    if let formatted = JSONHighlighter.prettyPrint(draft.message) { change { $0.message = formatted } }
                }
                .controlSize(.small)
            }
            CodeEditor(
                text: Binding(get: { draft.message }, set: { text in change { $0.message = text } }),
                highlightsJSON: true,
                variables: app.variableScope
            )
            .background(Theme.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius).strokeBorder(Theme.hairline))
            if draft.methodType == "client-streaming" || draft.methodType == "bidi-streaming" {
                Text("Streaming method: write a JSON array to send several messages in order.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var schemaSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Gowa learns the service's methods and message shapes from server reflection. If the server doesn't offer reflection, point it at a descriptor set or a .proto file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                VariableField("Leave empty to use server reflection", text: Binding(
                    get: { draft.protoFilePath },
                    set: { path in change { $0.protoFilePath = path } }
                ))
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(Theme.fieldFill, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
                .accessibilityLabel("Descriptor or proto file")
                Button("Choose…") {
                    app.chooseFile { path in change { $0.protoFilePath = path } }
                }
                Button(session.loadingSchema ? "Loading…" : "Load Methods") { app.loadGrpcSchema() }
                    .disabled(session.loadingSchema)
            }
            Text("Descriptor sets (.binpb, .pb, .protoset) work as is: protoc --include_imports --descriptor_set_out=api.binpb api.proto. A .proto file is compiled with protoc or buf when installed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let schema = session.schema {
                Text("\(schema.methods.count) methods from \(session.schemaSource)")
                    .font(.caption.weight(.medium))
            }
            Spacer()
        }
        .padding(16)
    }

    private func choose(_ method: ProtoSchema.Method) {
        change { snapshot in
            let switching = snapshot.method != method.fullName
            snapshot.method = method.fullName
            snapshot.methodType = method.kind
            if switching, let schema = session.schema {
                let template = ProtoCodec(schema: schema).template(for: method.input)
                snapshot.message = JSONPath.render([method.clientStreaming ? [template] : template])
            }
        }
    }

    private func change(_ edit: (inout OCGrpcSnapshot) -> Void) {
        var copy = draft
        edit(&copy)
        app.updateGrpcDraft(copy)
    }
}

private struct GrpcResultView: View {
    let session: GrpcSession
    @State private var tab = Tab.responses

    enum Tab: String, CaseIterable, Identifiable {
        case responses = "Responses"
        case headers = "Headers"
        case trailers = "Trailers"
        var id: String { rawValue }
    }

    var body: some View {
        if session.calling, session.liveResponses.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(session.loadingSchema ? "Loading methods…" : "Calling…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let result = session.result {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TabStrip(tabs: Tab.allCases, selection: $tab, title: \.rawValue) { tab in
                        switch tab {
                        case .responses: result.responses.count
                        case .headers: result.headers.count
                        case .trailers: result.trailers.count
                        }
                    }
                    Spacer()
                    HStack(spacing: 5) {
                        Circle().fill(result.ok ? Color.green : Color.red).frame(width: 7, height: 7)
                        Text(result.status).font(.callout.weight(.semibold)).foregroundStyle(result.ok ? Color.green : Color.red)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background((result.ok ? Color.green : Color.red).opacity(0.13), in: Capsule())
                    Text(result.elapsed.millisecondsText).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                if !result.statusMessage.isEmpty {
                    Text(result.statusMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .textSelection(.enabled)
                }
                Divider()
                switch tab {
                case .responses: responses(result.responses)
                case .headers: metadataList(result.headers)
                case .trailers: metadataList(result.trailers)
                }
            }
        } else if !session.liveResponses.isEmpty {
            responses(session.liveResponses)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text("No response yet").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                Text("Load methods, choose one, then Invoke (⌘↩)").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func responses(_ items: [String]) -> some View {
        let text = items.count == 1 ? items[0] : items.enumerated().map { "// message \($0.offset + 1)\n\($0.element)" }.joined(separator: "\n\n")
        return CodeViewer(text: text, runs: JSONHighlighter.runs(text), isJSON: true)
    }

    private func metadataList(_ pairs: [(name: String, value: String)]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pairs.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Text(pairs[index].name).font(.system(.callout, design: .monospaced).weight(.medium)).frame(width: 220, alignment: .leading)
                        Text(pairs[index].value).font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
                if pairs.isEmpty { Text("None").font(.callout).foregroundStyle(.tertiary) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
