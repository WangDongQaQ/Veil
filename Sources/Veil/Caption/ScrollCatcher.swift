import SwiftUI
import AppKit

/// Receives scroll-wheel / trackpad events for the caption area and reports how far to scroll.
/// Only present while the panel is accepting mouse events (hovering overflowing text).
struct ScrollCatcher: NSViewRepresentable {
    /// Points to scroll *down* by; negative scrolls back up towards older text.
    var onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: ((CGFloat) -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func scrollWheel(with event: NSEvent) {
            // scrollingDeltaY already follows the user's natural-scrolling setting: content moves with the
            // fingers, so a positive delta shows earlier text. A notched mouse wheel reports lines, not points.
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 14
            onScroll?(-event.scrollingDeltaY * scale)
        }
    }
}
