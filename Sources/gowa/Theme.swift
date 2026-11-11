import AppKit
import SwiftUI

enum Theme {
    static let hairline = Color(nsColor: .separatorColor)
    static let fieldFill = Color(nsColor: .textBackgroundColor)
    static let cornerRadius: CGFloat = 8

    static let environmentColors: [(name: String, hex: String)] = [
        ("Red", "#E5484D"), ("Orange", "#F76B15"), ("Yellow", "#E2A336"),
        ("Green", "#30A46C"), ("Blue", "#0090FF"), ("Purple", "#8E4EC6"), ("Gray", "#8B8D98"),
    ]

    /// A filled dot that keeps its color in toolbars, which draw symbols as templates.
    static func dot(_ color: Color, size: CGFloat = 10) -> Image {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image)
    }

    /// `#RRGGBB` (spec environment colors); nil for anything else.
    static func color(hex: String?) -> Color? {
        guard var text = hex?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    static func methodColor(_ method: String?) -> Color {
        switch method?.uppercased() {
        case "GET": .green
        case "POST": .blue
        case "PUT", "PATCH": .orange
        case "DELETE": .red
        case "HEAD", "OPTIONS": .purple
        default: .secondary
        }
    }

    /// Sidebar badge: the HTTP method, or the protocol for other item types.
    static func badge(kind: String, method: String?) -> String {
        switch kind {
        case "graphql": "GQL"
        case "websocket": "WS"
        case "grpc": "gRPC"
        default: shortMethod(method)
        }
    }

    static func badgeColor(kind: String, method: String?) -> Color {
        switch kind {
        case "graphql": .pink
        case "websocket": .teal
        case "grpc": .indigo
        default: methodColor(method)
        }
    }

    static func shortMethod(_ method: String?) -> String {
        switch method?.uppercased() {
        case "DELETE": "DEL"
        case "OPTIONS": "OPT"
        case let other?: other
        case nil: "HTTP"
        }
    }
}

struct TabStrip<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    var badge: (Tab) -> Int = { _ in 0 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            strip
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var strip: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = tab == selection
                Button {
                    selection = tab
                } label: {
                    HStack(spacing: 5) {
                        Text(title(tab))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .fixedSize()
                        if badge(tab) > 0 {
                            Text("\(badge(tab))")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.primary.opacity(0.08), in: Capsule())
                        }
                    }
                    .foregroundStyle(selected ? .primary : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Color.primary.opacity(selected ? 0.09 : 0),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

struct FieldTable<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.hairline)
            )
    }
}

struct TableRow<Content: View>: View {
    var isHeader = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) { content }
                .padding(.horizontal, 10)
                .padding(.vertical, isHeader ? 5 : 6)
                .background(Color.primary.opacity(isHeader ? 0.04 : 0))
            Divider()
        }
        .font(isHeader ? .caption.weight(.medium) : .callout)
        .foregroundStyle(isHeader ? .secondary : .primary)
    }
}

struct RemoveRowButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tertiary)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct AddRowButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(label, systemImage: "plus")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

struct IconButton: View {
    let title: String
    let systemImage: String
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help ?? title)
        .accessibilityLabel(title)
    }
}
