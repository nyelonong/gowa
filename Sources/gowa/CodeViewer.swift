import AppKit
import SwiftUI

/// Collapsible `{…}` / `[…]` blocks in pretty-printed JSON, by line.
enum CodeFolding {
    /// Start line → end line for every block that spans more than one line.
    static func foldRanges(_ lines: [Substring]) -> [Int: Int] {
        var ranges: [Int: Int] = [:]
        var stack: [Int] = []
        for (index, line) in lines.enumerated() {
            var inString = false
            var escaped = false
            for character in line {
                if inString {
                    if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                    continue
                }
                switch character {
                case "\"": inString = true
                case "{", "[": stack.append(index)
                case "}", "]":
                    if let start = stack.popLast(), index > start { ranges[start] = index }
                default: break
                }
            }
        }
        return ranges
    }

    /// The text with folded blocks collapsed to one line, plus the original
    /// line number (0-based) of every shown line.
    static func render(_ lines: [Substring], folded: Set<Int>, ranges: [Int: Int]) -> (text: String, lineNumbers: [Int]) {
        var output: [String] = []
        var numbers: [Int] = []
        var index = 0
        while index < lines.count {
            if folded.contains(index), let end = ranges[index] {
                let closing = lines[end].trimmingCharacters(in: .whitespaces)
                output.append(String(lines[index]) + " … " + closing)
                numbers.append(index)
                index = end + 1
            } else {
                output.append(String(lines[index]))
                numbers.append(index)
                index += 1
            }
        }
        return (output.joined(separator: "\n"), numbers)
    }
}

/// Native TextKit viewer for response bodies — fast at megabyte scale,
/// selectable, with line numbers, optional wrapping, and JSON folding.
struct CodeViewer: NSViewRepresentable {
    let text: String
    let runs: [JSONHighlighter.Run]
    var findTrigger: Int = 0
    var isJSON = false
    var wraps = true

    /// Folding is offered up to this many lines; beyond it the viewer stays plain.
    static let foldingLineLimit = 50_000

    final class Coordinator {
        var lastFindTrigger: Int
        var sourceText: String?
        var lines: [Substring] = []
        var ranges: [Int: Int] = [:]
        var folded: Set<Int> = []
        var lineNumbers: [Int] = []
        var lineStarts: [Int] = [0]
        var wraps: Bool?

        init(lastFindTrigger: Int) { self.lastFindTrigger = lastFindTrigger }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(lastFindTrigger: findTrigger)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layout.addTextContainer(container)
        let textView = NSTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.allowsUndo = false
        textView.font = Theme.nsMono(13)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 12)
        textView.autoresizingMask = [.width]
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false

        let coordinator = context.coordinator
        let ruler = LineNumberRuler(scrollView: scroll, textView: textView, coordinator: coordinator) { [weak textView] line in
            guard let textView else { return }
            Self.toggleFold(line, textView: textView, coordinator: coordinator)
        }
        scroll.verticalRulerView = ruler
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator

        if coordinator.wraps != wraps {
            coordinator.wraps = wraps
            Self.applyWrapping(wraps, textView: textView, scroll: scroll)
        }

        if coordinator.sourceText != text {
            coordinator.sourceText = text
            coordinator.lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            coordinator.folded = []
            coordinator.ranges = isJSON && coordinator.lines.count <= Self.foldingLineLimit ? CodeFolding.foldRanges(coordinator.lines) : [:]
            coordinator.lineNumbers = Array(0..<coordinator.lines.count)
            coordinator.lineStarts = Self.lineStarts(text)
            textView.textStorage?.setAttributedString(JSONHighlighter.attributed(text, runs: runs))
            textView.scrollToBeginningOfDocument(nil)
            scroll.verticalRulerView?.needsDisplay = true
        }

        if coordinator.lastFindTrigger != findTrigger {
            coordinator.lastFindTrigger = findTrigger
            textView.window?.makeFirstResponder(textView)
            let showFindBar = NSMenuItem()
            showFindBar.tag = NSTextFinder.Action.showFindInterface.rawValue
            textView.performTextFinderAction(showFindBar)
        }
    }

    private static func applyWrapping(_ wraps: Bool, textView: NSTextView, scroll: NSScrollView) {
        guard let container = textView.textContainer else { return }
        if wraps {
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            container.widthTracksTextView = true
            textView.frame.size.width = scroll.contentSize.width
            scroll.hasHorizontalScroller = false
        } else {
            textView.isHorizontallyResizable = true
            textView.autoresizingMask = []
            container.widthTracksTextView = false
            container.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scroll.hasHorizontalScroller = true
        }
        textView.layoutManager?.ensureLayout(for: container)
        textView.sizeToFit()
        scroll.verticalRulerView?.needsDisplay = true
    }

    static func lineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var offset = 0
        for unit in text.utf16 {
            offset += 1
            if unit == 0x0A { starts.append(offset) }
        }
        return starts
    }

    fileprivate static func toggleFold(_ displayLine: Int, textView: NSTextView, coordinator: Coordinator) {
        guard displayLine < coordinator.lineNumbers.count else { return }
        let original = coordinator.lineNumbers[displayLine]
        guard coordinator.ranges[original] != nil else { return }
        if coordinator.folded.contains(original) {
            coordinator.folded.remove(original)
        } else {
            coordinator.folded.insert(original)
        }
        let rendered = CodeFolding.render(coordinator.lines, folded: coordinator.folded, ranges: coordinator.ranges)
        coordinator.lineNumbers = rendered.lineNumbers
        coordinator.lineStarts = lineStarts(rendered.text)
        let origin = textView.visibleRect.origin
        textView.textStorage?.setAttributedString(JSONHighlighter.attributed(rendered.text, runs: JSONHighlighter.runs(rendered.text)))
        textView.scroll(origin)
        textView.enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }
}

/// Line numbers with fold markers; clicking a marker folds or unfolds its block.
private final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let coordinator: CodeViewer.Coordinator
    private let onToggle: (Int) -> Void
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    init(scrollView: NSScrollView, textView: NSTextView, coordinator: CodeViewer.Coordinator, onToggle: @escaping (Int) -> Void) {
        self.textView = textView
        self.coordinator = coordinator
        self.onToggle = onToggle
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: NSText.didChangeNotification, object: textView)
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func redraw() { needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = layout.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        let starts = coordinator.lineStarts
        var lastLine = -1
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let markerAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, glyphRange, _ in
            let charIndex = layout.characterIndexForGlyph(at: glyphRange.location)
            let line = Self.line(for: charIndex, starts: starts)
            guard line != lastLine else { return }
            lastLine = line
            let top = self.convert(NSPoint(x: 0, y: fragment.minY + textView.textContainerInset.height), from: textView).y
            let original = line < self.coordinator.lineNumbers.count ? self.coordinator.lineNumbers[line] : line
            let label = "\(original + 1)" as NSString
            let size = label.size(withAttributes: numberAttributes)
            label.draw(at: NSPoint(x: self.ruleThickness - size.width - 16, y: top + (fragment.height - size.height) / 2), withAttributes: numberAttributes)
            if self.coordinator.ranges[original] != nil {
                let marker = (self.coordinator.folded.contains(original) ? "▶" : "▼") as NSString
                marker.draw(at: NSPoint(x: self.ruleThickness - 12, y: top + (fragment.height - 11) / 2), withAttributes: markerAttributes)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let glyph = layout.glyphIndex(for: NSPoint(x: 0, y: point.y - textView.textContainerInset.height), in: container)
        let charIndex = layout.characterIndexForGlyph(at: glyph)
        onToggle(Self.line(for: charIndex, starts: coordinator.lineStarts))
        needsDisplay = true
    }

    static func line(for charIndex: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= charIndex { low = mid } else { high = mid - 1 }
        }
        return low
    }
}
