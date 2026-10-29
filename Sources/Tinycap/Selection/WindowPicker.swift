import AppKit
import ScreenCaptureKit
import TinycapCore

/// Window mode (CS-1): hovering highlights the window under the cursor, a click selects it.
/// Tinycap's own windows are never offered.
@MainActor
final class WindowPickerController {
    struct Candidate {
        let window: SCWindow
        /// Window frame in AppKit global coordinates.
        let frame: CGRect
        let title: String
    }

    private let candidates: [Candidate]
    private let purpose: SelectionPurpose
    private var panels: [OverlayPanel] = []
    private var views: [WindowPickerView] = []
    private var hovered: Candidate?
    private var continuation: CheckedContinuation<CGWindowID?, Never>?

    init(content: SCShareableContent, purpose: SelectionPurpose = .record) {
        candidates = Self.candidates(from: content)
        self.purpose = purpose
    }

    /// Returns the chosen window's ID, or nil if cancelled.
    func run() async -> CGWindowID? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
    }

    /// On-screen windows front to back. ScreenCaptureKit doesn't promise an order, so the
    /// z-order comes from CGWindowList and the capture objects from SCShareableContent.
    private static func candidates(from content: SCShareableContent) -> [Candidate] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let primaryHeight = NSScreen.primaryHeight

        return info.compactMap { entry -> Candidate? in
            guard let number = entry[kCGWindowNumber as String] as? NSNumber,
                  let window = byID[CGWindowID(number.uint32Value)],
                  window.windowLayer == 0,
                  window.isOnScreen,
                  window.frame.width >= 40, window.frame.height >= 40,
                  let app = window.owningApplication,
                  app.processID != ownPID
            else { return nil }
            let title = [app.applicationName, window.title ?? ""].filter { !$0.isEmpty }.joined(separator: " — ")
            return Candidate(
                window: window,
                frame: Geometry.appKitRect(fromCG: window.frame, primaryScreenHeight: primaryHeight),
                title: title
            )
        }
    }

    private func show() {
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = WindowPickerView(frame: CGRect(origin: .zero, size: screen.frame.size), screenFrame: screen.frame, verb: purpose.verb)
            view.onMove = { [weak self] in self?.updateHover() }
            view.onClick = { [weak self] in self?.clicked() }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panel.orderFrontRegardless()
            panels.append(panel)
            views.append(view)
        }
        let keyPanel = panels.first { NSMouseInRect(NSEvent.mouseLocation, $0.screenFrame, false) } ?? panels.first
        keyPanel?.makeKey()
        if let view = keyPanel?.contentView { keyPanel?.makeFirstResponder(view) }
        NSApp.activate()
        updateHover()
    }

    private func updateHover() {
        let p = NSEvent.mouseLocation
        let candidate = candidates.first { $0.frame.contains(p) }
        guard candidate?.window.windowID != hovered?.window.windowID else { return }
        hovered = candidate
        for view in views {
            view.highlight = candidate.map { ($0.frame, $0.title) }
        }
    }

    private func clicked() {
        updateHover()
        guard let hovered else { return }
        finish(hovered.window.windowID)
    }

    private func finish(_ windowID: CGWindowID?) {
        guard let continuation else { return }
        self.continuation = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        continuation.resume(returning: windowID)
    }
}

final class WindowPickerView: NSView {
    var onMove: (() -> Void)?
    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?
    var highlight: (frame: CGRect, title: String)? {
        didSet { needsDisplay = true }
    }

    private let screenFrame: CGRect
    private let verb: String

    init(frame: NSRect, screenFrame: CGRect, verb: String) {
        self.screenFrame = screenFrame
        self.verb = verb
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Window selection. Click a window to \(verb) it, press Escape to cancel.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseMoved(with event: NSEvent) { onMove?() }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == OverlayKey.escape { onCancel?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.15).setFill()
        bounds.fill()

        guard let highlight else {
            OverlayLabel.draw("Click a window to \(verb) · Esc to cancel",
                              centeredAt: CGPoint(x: bounds.midX, y: bounds.midY), in: bounds, fontSize: 15)
            return
        }
        let local = highlight.frame.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
        guard local.intersects(bounds) else { return }

        NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
        local.fill()
        let path = NSBezierPath(rect: local.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 3
        NSColor.controlAccentColor.setStroke()
        path.stroke()

        let visible = local.intersection(bounds)
        OverlayLabel.draw(highlight.title.isEmpty ? "Click to \(verb)" : "\(highlight.title) · Click to \(verb)",
                          centeredAt: CGPoint(x: visible.midX, y: visible.midY), in: bounds, fontSize: 13)
    }
}
