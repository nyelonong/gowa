import AppKit
import SwiftUI

enum Theme {
    static let hairline = Color.primary.opacity(0.09)
    static let fieldFill = Color.primary.opacity(0.04)
    static let cornerRadius: CGFloat = 8
    static let panelRadius: CGFloat = 12
    static let paneGap: CGFloat = 10

    static let glassKey = "gowa.glass"
    static let ligaturesKey = "gowa.codeLigatures"

    // MARK: Code font

    /// JetBrains Mono ships in the app bundle (registered through
    /// `ATSApplicationFontsPath`); a plain `swift run` falls back to SF Mono.
    nonisolated(unsafe) private static let fontCache = NSCache<NSString, NSFont>()

    static func nsMono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let ligatures = UserDefaults.standard.object(forKey: ligaturesKey) as? Bool ?? true
        let key = "\(size)-\(weight.rawValue)-\(ligatures)" as NSString
        if let cached = fontCache.object(forKey: key) { return cached }
        let name = switch weight {
        case .bold, .heavy, .black: "JetBrainsMono-Bold"
        case .semibold: "JetBrainsMono-SemiBold"
        case .medium: "JetBrainsMono-Medium"
        default: "JetBrainsMono-Regular"
        }
        var font = NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: weight)
        if !ligatures {
            let off: [[NSFontDescriptor.FeatureKey: Int]] = [
                [.typeIdentifier: kLigaturesType, .selectorIdentifier: kCommonLigaturesOffSelector],
                [.typeIdentifier: kContextualAlternatesType, .selectorIdentifier: kContextualAlternatesOffSelector],
            ]
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: off])
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        fontCache.setObject(font, forKey: key)
        return font
    }

    static func mono(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(nsMono(size, weight: nsWeight(weight)))
    }

    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        let size: CGFloat = switch style {
        case .caption, .caption2, .footnote: 10.5
        case .subheadline: 11
        case .callout: 12
        case .title3: 15
        default: 13
        }
        return mono(size: size, weight: weight)
    }

    private static func nsWeight(_ weight: Font.Weight) -> NSFont.Weight {
        switch weight {
        case .bold, .heavy, .black: .bold
        case .semibold: .semibold
        case .medium: .medium
        default: .regular
        }
    }

    // MARK: Palette

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    enum Syntax {
        static let key = dynamic(light: rgb(0xBE185D), dark: rgb(0x7DD3FC))
        static let string = dynamic(light: rgb(0x047857), dark: rgb(0x86EFAC))
        static let number = dynamic(light: rgb(0xB45309), dark: rgb(0xFCD34D))
        static let literal = dynamic(light: rgb(0x6D28D9), dark: rgb(0xC4B5FD))
        static let punctuation = dynamic(light: rgb(0x17171C, 0.45), dark: rgb(0xEDEDF2, 0.42))
    }

    static let panelFill = Color(nsColor: dynamic(light: rgb(0xFFFFFF, 0.78), dark: rgb(0x0A0A0E, 0.5)))
    static let panelSolid = Color(nsColor: .textBackgroundColor)
    static let panelHairline = Color(nsColor: dynamic(light: rgb(0x0F0F1E, 0.09), dark: rgb(0xFFFFFF, 0.08)))

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

    private static let methodGreen = Color(nsColor: dynamic(light: rgb(0x047857), dark: rgb(0x34D399)))
    private static let methodBlue = Color(nsColor: dynamic(light: rgb(0x1D4ED8), dark: rgb(0x60A5FA)))
    private static let methodOrange = Color(nsColor: dynamic(light: rgb(0xB45309), dark: rgb(0xFBBF24)))
    private static let methodRed = Color(nsColor: dynamic(light: rgb(0xB91C1C), dark: rgb(0xF87171)))
    private static let methodPurple = Color(nsColor: dynamic(light: rgb(0x6D28D9), dark: rgb(0xC4B5FD)))
    private static let methodPink = Color(nsColor: dynamic(light: rgb(0xBE185D), dark: rgb(0xF472B6)))
    private static let methodTeal = Color(nsColor: dynamic(light: rgb(0x0E7490), dark: rgb(0x22D3EE)))
    private static let methodIndigo = Color(nsColor: dynamic(light: rgb(0x4338CA), dark: rgb(0xA5B4FC)))

    static func methodColor(_ method: String?) -> Color {
        switch method?.uppercased() {
        case "GET": methodGreen
        case "POST": methodBlue
        case "PUT", "PATCH": methodOrange
        case "DELETE": methodRed
        case "HEAD", "OPTIONS": methodPurple
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
        case "graphql": methodPink
        case "websocket": methodTeal
        case "grpc": methodIndigo
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

/// Sidebar-style method label: colored text on a soft pill of the same color.
struct MethodBadge: View {
    let kind: String
    let method: String?
    var width: CGFloat = 38

    var body: some View {
        let color = Theme.badgeColor(kind: kind, method: method)
        Text(Theme.badge(kind: kind, method: method))
            .font(Theme.mono(size: 9.5, weight: .bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: width)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(method ?? kind)
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
