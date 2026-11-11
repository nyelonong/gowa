import AppKit
import SwiftUI

/// Variables visible to a field: what `{{name}}` resolves to at send time.
struct VariableScope: Equatable {
    var values: [String: String]
    var secretNames: Set<String> = []

    enum State { case defined, undefined, function }

    func state(of token: String) -> State {
        if token.hasPrefix("$") {
            let name = token.dropFirst().split(separator: "(").first.map(String.init) ?? ""
            return TemplateFunctions.isKnown(name.trimmingCharacters(in: .whitespaces)) ? .function : .undefined
        }
        return values[token] != nil ? .defined : .undefined
    }

    func isDefined(_ token: String) -> Bool { state(of: token) != .undefined }

    func tooltip(for token: String) -> String {
        switch state(of: token) {
        case .function:
            let name = token.dropFirst().split(separator: "(").first.map(String.init) ?? ""
            return TemplateFunctions.catalog.first { $0.name == name }?.summary ?? "Built-in function"
        case .defined:
            let value = values[token] ?? ""
            return secretNames.contains(token) ? "{{\(token)}} = ••••••" : "{{\(token)}} = \(value.isEmpty ? "(empty)" : value)"
        case .undefined:
            return "{{\(token)}} isn't defined in the active environment, folder, or collection"
        }
    }

    /// Completions for a partial name typed after `{{`.
    func completions(for partial: String) -> [String] {
        let lower = partial.lowercased()
        let names = values.keys.sorted { $0.lowercased() < $1.lowercased() }.filter { $0.lowercased().hasPrefix(lower) }
        let functions = TemplateFunctions.catalog.map { "$" + $0.name }.filter { $0.lowercased().hasPrefix(lower) }
        return names + (partial.isEmpty || partial.hasPrefix("$") ? functions : [])
    }

    static let tokenPattern = try! NSRegularExpression(pattern: #"\{\{\s*([^{}]+?)\s*\}\}"#)
}

/// Single-line text field that colors `{{variables}}` (green when defined,
/// red when not, purple for functions), shows their values on hover, and
/// completes names after `{{`.
struct VariableField: View {
    let placeholder: String
    @Binding var text: String
    var variables: VariableScope?
    var fontSize: CGFloat = 12
    var onSubmit: (() -> Void)?
    var onPaste: ((String) -> Bool)?

    init(
        _ placeholder: String,
        text: Binding<String>,
        variables: VariableScope? = nil,
        fontSize: CGFloat = 12,
        onSubmit: (() -> Void)? = nil,
        onPaste: ((String) -> Bool)? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.variables = variables
        self.fontSize = fontSize
        self.onSubmit = onSubmit
        self.onPaste = onPaste
    }

    var body: some View {
        TokenTextView(text: $text, variables: variables, fontSize: fontSize, onSubmit: onSubmit, onPaste: onPaste)
            .frame(height: fontSize + 8)
            .overlay(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: fontSize, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct TokenTextView: NSViewRepresentable {
    @Binding var text: String
    var variables: VariableScope?
    var fontSize: CGFloat
    var onSubmit: (() -> Void)?
    var onPaste: ((String) -> Bool)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SingleLineTextView()
        textView.delegate = context.coordinator
        textView.coordinator = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.maximumNumberOfLines = 1
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: fontSize + 8)
        textView.string = text
        context.coordinator.highlight(textView)

        let scroll = SingleLineScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? SingleLineTextView else { return }
        let coordinator = context.coordinator
        let scopeChanged = coordinator.parent.variables != variables
        coordinator.parent = self
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            coordinator.highlight(textView)
        } else if scopeChanged {
            coordinator.highlight(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TokenTextView

        init(_ parent: TokenTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let flattened = textView.string.replacingOccurrences(of: "\n", with: " ")
            if flattened != textView.string { textView.string = flattened }
            parent.text = textView.string
            highlight(textView)
            textView.sizeToFit()
            textView.scrollRangeToVisible(textView.selectedRange())
            if partialToken(in: textView) != nil, !(textView as? SingleLineTextView)!.isCompleting {
                textView.complete(nil)
            }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit?()
                return parent.onSubmit != nil
            case #selector(NSResponder.insertTab(_:)):
                textView.window?.selectNextKeyView(nil)
                return true
            case #selector(NSResponder.insertBacktab(_:)):
                textView.window?.selectPreviousKeyView(nil)
                return true
            default:
                return false
            }
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let scope = parent.variables, let partial = partialToken(in: textView) else { return [] }
            index?.pointee = 0
            return scope.completions(for: partial.text).map { $0 + "}}" }
        }

        /// The name typed so far after an unclosed `{{` before the cursor.
        func partialToken(in textView: NSTextView) -> (text: String, range: NSRange)? {
            let string = textView.string as NSString
            let cursor = textView.selectedRange().location
            guard cursor != NSNotFound, cursor <= string.length else { return nil }
            let before = string.substring(to: cursor)
            guard let open = before.range(of: "{{", options: .backwards) else { return nil }
            let typed = String(before[open.upperBound...])
            guard !typed.contains("}"), typed.allSatisfy({ $0.isLetter || $0.isNumber || "_$-.".contains($0) }) else { return nil }
            let start = (before as NSString).length - (typed as NSString).length
            return (typed, NSRange(location: start, length: cursor - start))
        }

        func highlight(_ textView: NSTextView) {
            guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)
            if let scope = parent.variables {
                for match in VariableScope.tokenPattern.matches(in: storage.string, range: full) {
                    let token = (storage.string as NSString).substring(with: match.range(at: 1))
                    let color: NSColor = switch scope.state(of: token) {
                    case .defined: .systemGreen
                    case .undefined: .systemRed
                    case .function: .systemPurple
                    }
                    storage.addAttributes([
                        .foregroundColor: color,
                        .backgroundColor: color.withAlphaComponent(0.12),
                        .toolTip: scope.tooltip(for: token),
                    ], range: match.range)
                }
            }
            storage.endEditing()
            textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        }
    }
}

/// Keeps the text view at least as large as the visible area so a click
/// anywhere focuses it, and lets long values scroll sideways.
final class SingleLineScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let size = contentView.bounds.size
        textView.minSize = NSSize(width: size.width, height: size.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: size.height)
        textView.sizeToFit()
        if textView.frame.height != size.height || textView.frame.width < size.width {
            textView.frame = NSRect(x: 0, y: 0, width: max(textView.frame.width, size.width), height: size.height)
        }
    }
}

final class SingleLineTextView: NSTextView {
    weak var coordinator: AnyObject?
    var isCompleting = false

    override var rangeForUserCompletion: NSRange {
        if let coordinator = coordinator as? TokenTextViewCoordinatorBridge, let range = coordinator.completionRange(self) {
            return range
        }
        return super.rangeForUserCompletion
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        isCompleting = true
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        isCompleting = !flag
    }

    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string),
           let coordinator = coordinator as? TokenTextViewCoordinatorBridge,
           coordinator.handlePaste(text) {
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            super.paste(sender)
            return
        }
        insertText(text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "), replacementRange: selectedRange())
    }

    override var acceptsFirstResponder: Bool { isEditable }
}

@MainActor
protocol TokenTextViewCoordinatorBridge: AnyObject {
    func completionRange(_ textView: NSTextView) -> NSRange?
    func handlePaste(_ text: String) -> Bool
}

extension TokenTextView.Coordinator: TokenTextViewCoordinatorBridge {
    func completionRange(_ textView: NSTextView) -> NSRange? {
        partialToken(in: textView)?.range
    }

    func handlePaste(_ text: String) -> Bool {
        parent.onPaste?(text) ?? false
    }
}
