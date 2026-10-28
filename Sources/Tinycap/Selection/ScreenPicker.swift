import AppKit

/// Screen mode (CS-2): with one display, picks it straight away; with several, the user
/// clicks the display to record.
@MainActor
final class ScreenPickerController {
    private var panels: [OverlayPanel] = []
    private var views: [ScreenPickerView] = []
    private var continuation: CheckedContinuation<CGDirectDisplayID?, Never>?

    /// Returns the chosen display's ID, or nil if cancelled.
    func run() async -> CGDirectDisplayID? {
        let screens = NSScreen.screens
        if screens.count == 1 { return screens[0].displayID }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            show(screens)
        }
    }

    private func show(_ screens: [NSScreen]) {
        for (index, screen) in screens.enumerated() {
            let panel = OverlayPanel(screen: screen)
            let view = ScreenPickerView(frame: CGRect(origin: .zero, size: screen.frame.size), name: "\(screen.localizedName) (\(index + 1) of \(screens.count))")
            let displayID = screen.displayID
            view.onClick = { [weak self] in self?.finish(displayID) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panel.orderFrontRegardless()
            if NSMouseInRect(NSEvent.mouseLocation, screen.frame, false) {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
            panels.append(panel)
            views.append(view)
        }
        NSApp.activate()
    }

    private func finish(_ displayID: CGDirectDisplayID?) {
        guard let continuation else { return }
        self.continuation = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        continuation.resume(returning: displayID)
    }
}

final class ScreenPickerView: NSView {
    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?
    private let name: String
    private var hovering = false {
        didSet { if hovering != oldValue { needsDisplay = true } }
    }

    init(frame: NSRect, name: String) {
        self.name = name
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Record \(name)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseEntered(with event: NSEvent) {
        hovering = true
        window?.makeKey()
        window?.makeFirstResponder(self)
    }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case OverlayKey.escape: onCancel?()
        case OverlayKey.returnKey, OverlayKey.enter: onClick?()
        default: super.keyDown(with: event)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovering {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill()
            bounds.fill()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 3, dy: 3))
            path.lineWidth = 6
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        } else {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
        }
        OverlayLabel.draw("Click to record \(name) · Esc to cancel",
                          centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds, fontSize: 15)
    }
}

/// Dashed outline around the area being recorded. Tinycap's own windows are excluded
/// from the capture, so the outline never shows up in the file.
final class RecordingBorderWindow: NSPanel {
    init(globalRect: CGRect) {
        let inset: CGFloat = 4
        super.init(contentRect: globalRect.insetBy(dx: -inset, dy: -inset), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = BorderView(inset: inset)
    }

    override var canBecomeKey: Bool { false }

    private final class BorderView: NSView {
        let inset: CGFloat
        init(inset: CGFloat) {
            self.inset = inset
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(rect: bounds.insetBy(dx: inset / 2, dy: inset / 2))
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            NSColor.systemRed.setStroke()
            path.stroke()
        }
    }
}
