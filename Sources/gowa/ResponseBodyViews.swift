import PDFKit
import SwiftUI
import WebKit

/// Collapsible tree of a JSON value; large arrays and objects show their
/// first 500 children.
struct JSONTreeView: View {
    let root: Any

    struct Node: Identifiable {
        let id: String
        let key: String
        let value: Any
        let isTruncationNote: Bool

        static let childLimit = 500

        var children: [Node]? {
            if let object = value as? [String: Any] {
                let keys = object.keys.sorted()
                var nodes = keys.prefix(Self.childLimit).map { Node(id: id + "." + $0, key: $0, value: object[$0]!, isTruncationNote: false) }
                if keys.count > Self.childLimit {
                    nodes.append(Node(id: id + ".…", key: "… \(keys.count - Self.childLimit) more keys", value: NSNull(), isTruncationNote: true))
                }
                return nodes.isEmpty ? nil : nodes
            }
            if let array = value as? [Any] {
                var nodes = array.prefix(Self.childLimit).enumerated().map { Node(id: id + "[\($0.offset)]", key: "[\($0.offset)]", value: $0.element, isTruncationNote: false) }
                if array.count > Self.childLimit {
                    nodes.append(Node(id: id + "[…]", key: "… \(array.count - Self.childLimit) more items", value: NSNull(), isTruncationNote: true))
                }
                return nodes.isEmpty ? nil : nodes
            }
            return nil
        }

        var summary: (text: String, color: Color) {
            switch value {
            case let object as [String: Any]: ("{ \(object.count) }", .secondary)
            case let array as [Any]: ("[ \(array.count) ]", .secondary)
            case let text as String: ("\"\(text)\"", .green)
            case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): (number.boolValue ? "true" : "false", .purple)
            case let number as NSNumber: (number.stringValue, .blue)
            default: ("null", .purple)
            }
        }
    }

    var body: some View {
        List {
            let rootNode = Node(id: "$", key: "$", value: root, isTruncationNote: false)
            OutlineGroup(rootNode.children ?? [rootNode], children: \.children) { node in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(node.key)
                        .font(.system(.callout, design: .monospaced).weight(node.isTruncationNote ? .regular : .medium))
                        .foregroundStyle(node.isTruncationNote ? Color.secondary : Color.pink)
                    if !node.isTruncationNote {
                        Text(node.summary.text)
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(node.summary.color)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                }
                .contextMenu {
                    if !node.isTruncationNote {
                        Button("Copy Path") { copy(node.id) }
                        Button("Copy Value") { copy(JSONPath.render([node.value])) }
                    }
                }
            }
        }
        .listStyle(.plain)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Renders images, PDFs, and HTML/SVG responses. HTML runs without
/// JavaScript and can't load anything from the network.
struct ResponsePreview: View {
    let result: HTTPResult

    enum Kind { case image, pdf, html }

    static func kind(for result: HTTPResult) -> Kind? {
        let type = (result.headers.first { $0.name.lowercased() == "content-type" }?.value ?? "").lowercased()
        if type.contains("svg") || type.contains("text/html") || type.contains("xhtml") { return .html }
        if type.hasPrefix("image/") { return .image }
        if type.contains("application/pdf") { return .pdf }
        let head = result.body.prefix(8)
        if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { return .pdf }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) || head.starts(with: [0xFF, 0xD8, 0xFF]) || head.starts(with: Array("GIF8".utf8)) { return .image }
        return nil
    }

    var body: some View {
        switch Self.kind(for: result) {
        case .image:
            if let image = NSImage(data: result.body) {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .interpolation(.high)
                        .padding(16)
                }
                .overlay(alignment: .bottomTrailing) {
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                        .font(.caption)
                        .padding(6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            } else {
                ContentUnavailableView("Can't show this image", systemImage: "photo")
            }
        case .pdf:
            PDFPreview(data: result.body)
        case .html:
            HTMLPreview(html: String(decoding: result.body, as: UTF8.self))
        case nil:
            ContentUnavailableView("No preview", systemImage: "eye.slash", description: Text("Previews cover images, PDFs, HTML, and SVG."))
        }
    }
}

private struct PDFPreview: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.dataRepresentation() != data { view.document = PDFDocument(data: data) }
    }
}

private struct HTMLPreview: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        Self.blockNetwork(view) { view.loadHTMLString(html, baseURL: nil) }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            action.navigationType == .other && action.request.url?.scheme == "about" ? .allow : .cancel
        }
    }

    /// Blocks every subresource load so a preview can't fetch trackers or remote assets.
    private static func blockNetwork(_ view: WKWebView, then load: @escaping @MainActor () -> Void) {
        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}}]"#
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "gowa-block-all", encodedContentRuleList: rules) { list, _ in
            MainActor.assumeIsolated {
                if let list {
                    view.configuration.userContentController.add(list)
                    load()
                } else {
                    view.loadHTMLString("<p style=\"font-family:-apple-system\">Preview unavailable: couldn't block network access.</p>", baseURL: nil)
                }
            }
        }
    }
}
