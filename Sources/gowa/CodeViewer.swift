import AppKit
import SwiftUI

/// Native TextKit viewer for response bodies — fast at megabyte scale,
/// selectable, dark/light adaptive.
struct CodeViewer: NSViewRepresentable {
    let text: String
    let runs: [JSONHighlighter.Run]
    var findTrigger: Int = 0

    final class Coordinator {
        var lastFindTrigger: Int
        init(lastFindTrigger: Int) { self.lastFindTrigger = lastFindTrigger }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(lastFindTrigger: findTrigger)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.autoresizingMask = [.width]
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }

        if context.coordinator.lastFindTrigger != findTrigger {
            context.coordinator.lastFindTrigger = findTrigger
            NSApp.keyWindow?.makeFirstResponder(textView)
            textView.performFindPanelAction(#selector(NSTextView.performFindPanelAction(_:)))
        }

        guard textView.string != text else { return }

        let attributed = JSONHighlighter.attributed(text, runs: runs)
        textView.textStorage?.setAttributedString(attributed)
        textView.scrollToBeginningOfDocument(nil)
    }
}
