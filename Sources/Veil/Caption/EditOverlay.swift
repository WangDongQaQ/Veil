import SwiftUI
import AppKit

/// Shown on top of the widget while it is being positioned: dashed outline, drag surface, corner grips.
struct EditOverlay: View {
    var onDone: () -> Void

    var body: some View {
        ZStack {
            // Non-zero alpha so the window server hit-tests the whole rectangle.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.black.opacity(0.28))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .padding(2)

            WindowDragSurface()

            VStack {
                HStack {
                    Spacer()
                    Button("完成", action: onDone)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Spacer()
                Text("拖动移动  ·  拖拽四角调整大小")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.5), radius: 2)
            }
            .padding(12)

            grip(.topLeft, .topLeading)
            grip(.topRight, .topTrailing)
            grip(.bottomLeft, .bottomLeading)
            grip(.bottomRight, .bottomTrailing)
        }
        .transition(.opacity)
    }

    private func grip(_ corner: ResizeGrip.Corner, _ alignment: Alignment) -> some View {
        ResizeGrip(corner: corner)
            .frame(width: 30, height: 30)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

// MARK: - AppKit helpers

/// Dragging anywhere on it moves the (non-activating) window.
struct WindowDragSurface: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}

struct ResizeGrip: NSViewRepresentable {
    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }
    let corner: Corner

    func makeNSView(context: Context) -> GripView { GripView(corner: corner) }
    func updateNSView(_ nsView: GripView, context: Context) {}

    final class GripView: NSView {
        let corner: Corner
        private var startMouse = NSPoint.zero
        private var startFrame = NSRect.zero
        private let minSize = NSSize(width: 160, height: 64)

        init(corner: Corner) {
            self.corner = corner
            super.init(frame: .zero)
            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.cursorUpdate, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
        required init?(coder: NSCoder) { fatalError() }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func cursorUpdate(with event: NSEvent) {
            let position: NSCursor.FrameResizePosition = switch corner {
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            NSCursor.frameResize(position: position, directions: .all).set()
        }

        override func draw(_ dirtyRect: NSRect) {
            let inset: CGFloat = 8, length: CGFloat = 14
            let path = NSBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            let b = bounds
            switch corner {
            case .topLeft:
                path.move(to: NSPoint(x: b.minX + inset, y: b.maxY - inset - length))
                path.line(to: NSPoint(x: b.minX + inset, y: b.maxY - inset))
                path.line(to: NSPoint(x: b.minX + inset + length, y: b.maxY - inset))
            case .topRight:
                path.move(to: NSPoint(x: b.maxX - inset - length, y: b.maxY - inset))
                path.line(to: NSPoint(x: b.maxX - inset, y: b.maxY - inset))
                path.line(to: NSPoint(x: b.maxX - inset, y: b.maxY - inset - length))
            case .bottomLeft:
                path.move(to: NSPoint(x: b.minX + inset, y: b.minY + inset + length))
                path.line(to: NSPoint(x: b.minX + inset, y: b.minY + inset))
                path.line(to: NSPoint(x: b.minX + inset + length, y: b.minY + inset))
            case .bottomRight:
                path.move(to: NSPoint(x: b.maxX - inset - length, y: b.minY + inset))
                path.line(to: NSPoint(x: b.maxX - inset, y: b.minY + inset))
                path.line(to: NSPoint(x: b.maxX - inset, y: b.minY + inset + length))
            }
            NSColor.white.withAlphaComponent(0.95).setStroke()
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            startMouse = NSEvent.mouseLocation
            startFrame = window.frame
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y   // screen coordinates: y grows upwards

            var left = startFrame.minX, right = startFrame.maxX
            var bottom = startFrame.minY, top = startFrame.maxY
            let movesLeft = corner == .topLeft || corner == .bottomLeft
            let movesTop = corner == .topLeft || corner == .topRight

            if movesLeft { left += dx; if right - left < minSize.width { left = right - minSize.width } }
            else { right += dx; if right - left < minSize.width { right = left + minSize.width } }
            if movesTop { top += dy; if top - bottom < minSize.height { top = bottom + minSize.height } }
            else { bottom += dy; if top - bottom < minSize.height { bottom = top - minSize.height } }

            window.setFrame(NSRect(x: left, y: bottom, width: right - left, height: top - bottom), display: true)
        }
    }
}
