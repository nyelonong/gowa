import AppKit
import SwiftUI

/// Editable TextKit view for request bodies. Colors JSON in place so the
/// cursor, selection, and undo stack survive each keystroke.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var highlightsJSON: Bool
    var variables: VariableScope? = nil

    private static var font: NSFont { Theme.nsMono(13) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var highlightedAsJSON: Bool
        var highlightedScope: VariableScope?

        init(parent: CodeEditor) {
            self.parent = parent
            self.highlightedAsJSON = parent.highlightsJSON
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            highlight(textView)
        }

        func highlight(_ textView: NSTextView) {
            // Restyling during input-method composition would cancel the marked text.
            guard let storage = textView.textStorage, !textView.hasMarkedText() else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.beginEditing()
            storage.setAttributes(
                [.font: CodeEditor.font, .foregroundColor: NSColor.labelColor],
                range: full
            )
            if parent.highlightsJSON {
                for run in JSONHighlighter.runs(textView.string) {
                    storage.addAttribute(.foregroundColor, value: run.kind.color, range: run.range)
                }
            }
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
            highlightedAsJSON = parent.highlightsJSON
            highlightedScope = parent.variables
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = Self.font
        textView.textColor = .labelColor
        textView.typingAttributes = [.font: Self.font, .foregroundColor: NSColor.labelColor]
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.autoresizingMask = [.width]
        textView.setAccessibilityLabel("Request body")

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self

        if textView.string != text {
            textView.string = text
            context.coordinator.highlight(textView)
        } else if context.coordinator.highlightedAsJSON != highlightsJSON || context.coordinator.highlightedScope != variables {
            context.coordinator.highlight(textView)
        }
    }
}
