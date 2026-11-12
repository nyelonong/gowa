import AppKit
import SwiftUI

/// Frosted window background: the desktop shows through, blurred, when the
/// Glass setting is on; a plain window background otherwise.
struct WindowBackground: NSViewRepresentable {
    var glass: Bool

    func makeNSView(context: Context) -> GlassHostView {
        let view = GlassHostView()
        view.blendingMode = .behindWindow
        view.material = .hudWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: GlassHostView, context: Context) {
        view.glass = glass
    }

    final class GlassHostView: NSVisualEffectView {
        var glass = true {
            didSet { if glass != oldValue { apply() } }
        }

        /// Materials of the effect views this view retinted, to put back
        /// exactly when Glass is turned off.
        private let originals = NSMapTable<NSVisualEffectView, NSNumber>.weakToStrongObjects()
        private var splitObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let splitObserver { NotificationCenter.default.removeObserver(splitObserver) }
            splitObserver = nil
            guard window != nil else { return }
            // Collapsing or expanding the sidebar resizes the split view
            // without laying this view out; its effect view can be new then.
            splitObserver = NotificationCenter.default.addObserver(
                forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.matchSidebar() }
            }
            apply()
        }

        override func layout() {
            super.layout()
            matchSidebar()
        }

        private func apply() {
            isHidden = !glass
            guard let window else { return }
            window.isOpaque = !glass
            window.backgroundColor = glass ? .clear : .windowBackgroundColor
            matchSidebar()
        }

        /// The split view's sidebar draws its own, thicker material; give it
        /// the window's so the glass reads as one surface.
        private func matchSidebar() {
            guard let root = window?.contentView?.superview else { return }
            func visit(_ view: NSView) {
                if let effect = view as? NSVisualEffectView, effect !== self, effect.blendingMode == .behindWindow {
                    if glass {
                        if originals.object(forKey: effect) == nil {
                            originals.setObject(NSNumber(value: effect.material.rawValue), forKey: effect)
                        }
                        if effect.material != material { effect.material = material }
                    } else if let original = originals.object(forKey: effect)?.intValue,
                              let restored = NSVisualEffectView.Material(rawValue: original) {
                        effect.material = restored
                        originals.removeObject(forKey: effect)
                    }
                }
                view.subviews.forEach(visit)
            }
            visit(root)
        }
    }
}

extension View {
    /// A rounded content panel that sits on the window background.
    func panel(glass: Bool) -> some View {
        background(glass ? Theme.panelFill : Theme.panelSolid, in: RoundedRectangle(cornerRadius: Theme.panelRadius))
            .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Theme.panelRadius).strokeBorder(Theme.panelHairline))
    }
}

/// Two panes with a gap between them; dragging the gap resizes them.
struct PaneSplit<First: View, Second: View>: View {
    let axis: Axis
    @Binding var fraction: Double
    var minFirst: CGFloat = 300
    var minSecond: CGFloat = 220
    @ViewBuilder var first: First
    @ViewBuilder var second: Second

    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { proxy in
            let total = max((axis == .horizontal ? proxy.size.width : proxy.size.height) - Theme.paneGap, 0)
            let firstLength = clamped(fraction, total: total) * total
            let layout = axis == .horizontal
                ? AnyLayout(HStackLayout(spacing: 0))
                : AnyLayout(VStackLayout(spacing: 0))
            layout {
                first
                    .frame(
                        width: axis == .horizontal ? firstLength : nil,
                        height: axis == .vertical ? firstLength : nil
                    )
                handle(total: total)
                second
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(
            minWidth: axis == .horizontal ? minFirst + minSecond + Theme.paneGap : nil,
            minHeight: axis == .vertical ? minFirst + minSecond + Theme.paneGap : nil
        )
    }

    private func clamped(_ value: Double, total: CGFloat) -> Double {
        guard total > 0 else { return value }
        let low = min(Double(minFirst / total), 0.5)
        let high = max(1 - Double(minSecond / total), 0.5)
        return min(max(value, low), high)
    }

    private func handle(total: CGFloat) -> some View {
        Color.clear
            .frame(
                width: axis == .horizontal ? Theme.paneGap : nil,
                height: axis == .vertical ? Theme.paneGap : nil
            )
            .contentShape(Rectangle())
            .pointerStyle(axis == .horizontal ? .columnResize : .rowResize)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? clamped(fraction, total: total)
                        if dragStart == nil { dragStart = start }
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        fraction = clamped(start + Double(delta / max(total, 1)), total: total)
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize panes")
            .accessibilityValue("\(Int((clamped(fraction, total: total) * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.05 : direction == .decrement ? -0.05 : 0
                fraction = clamped(clamped(fraction, total: total) + step, total: total)
            }
    }
}
