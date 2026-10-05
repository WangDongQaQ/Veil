import SwiftUI
import AppKit
import Combine

/// Borderless, transparent, non-activating panel — a desktop widget rather than a window.
final class CaptionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CaptionWindowController {
    let panel: CaptionPanel
    private let store: CaptionStore
    private let settings: AppSettings
    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private static let frameName = "Veil.CaptionWidget"
    private static let defaultSize = NSSize(width: 560, height: 150)

    init(store: CaptionStore, settings: AppSettings, onFinishEditing: @escaping () -> Void) {
        self.store = store
        self.settings = settings

        panel = CaptionPanel(contentRect: NSRect(origin: .zero, size: Self.defaultSize),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.titleVisibility = .hidden
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true                     // click-through unless editing
        panel.setAccessibilityLabel("实时字幕")

        let host = NSHostingView(rootView: CaptionView(store: store, settings: settings, onFinishEditing: onFinishEditing))
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = host

        if !panel.setFrameUsingName(Self.frameName) { panel.setFrame(defaultFrame(), display: false) }
        panel.setFrameAutosaveName(Self.frameName)
        keepOnScreen()

        apply(settings.p)
        settings.$p
            .map { [$0.windowLevel, $0.showOnAllSpaces] as [AnyHashable] }
            .removeDuplicates()
            .sink { [weak self] _ in if let self { self.apply(self.settings.p) } }
            .store(in: &cancellables)

        // Click-through unless editing, or hovering overflowing text that can be scrolled.
        Publishers.CombineLatest(store.$editMode, store.$wantsMouse)
            .sink { [weak self] editing, wantsMouse in
                self?.panel.ignoresMouseEvents = !(editing || wantsMouse)
                self?.updatePolling()
            }
            .store(in: &cancellables)

        // `hasContent` is derived, so re-evaluate polling after every change has landed.
        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updatePolling() }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.keepOnScreen() }
            .store(in: &cancellables)
    }

    // MARK: Visibility & placement

    func setVisible(_ visible: Bool) {
        if visible { panel.orderFrontRegardless() } else { panel.orderOut(nil) }
        updatePolling()
    }

    func resetPosition() {
        panel.setFrame(defaultFrame(), display: true, animate: true)
    }

    private func defaultFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = Self.defaultSize
        return NSRect(x: area.midX - size.width / 2, y: area.minY + 56, width: size.width, height: size.height)
    }

    /// If the display the widget lived on is gone, bring it back.
    private func keepOnScreen() {
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(panel.frame) }
        if !onScreen { panel.setFrame(defaultFrame(), display: true) }
    }

    private func apply(_ p: Preferences) {
        switch p.windowLevel {
        case .floating: panel.level = .floating
        case .normal: panel.level = .normal
        case .desktop: panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        behavior.insert(p.showOnAllSpaces ? .canJoinAllSpaces : .moveToActiveSpace)
        if p.windowLevel == .desktop { behavior.insert(.stationary) }
        panel.collectionBehavior = behavior
    }

    // MARK: Pointer tracking
    //
    // The panel ignores mouse events (so it never gets in the way of the apps underneath), which means
    // normal hover tracking can't work. Instead the pointer is sampled while there is something to reveal.

    private func updatePolling() {
        let needed = panel.isVisible && (store.hasContent || store.editMode)
        if needed, pollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollPointer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else if !needed, pollTimer != nil {
            pollTimer?.invalidate()
            pollTimer = nil
            if store.pointer != nil { store.pointer = nil }
        }
    }

    /// Lets the snapshot tool (and tests) place the pointer without a real mouse.
    var debugPointer: CGPoint?

    private func pollPointer() {
        if let debugPointer {
            if store.pointer != debugPointer { store.pointer = debugPointer }
            return
        }
        let mouse = NSEvent.mouseLocation
        let frame = panel.frame
        var local: CGPoint?
        if frame.insetBy(dx: -24, dy: -24).contains(mouse) {
            local = CGPoint(x: (mouse.x - frame.minX).rounded(), y: (frame.maxY - mouse.y).rounded())
        }
        if local != store.pointer { store.pointer = local }
    }
}
