import AppKit
import TinycapCore

struct AreaSelection: Sendable {
    let displayID: CGDirectDisplayID
    /// Frame of the selected display in AppKit global coordinates.
    let screenFrame: CGRect
    /// Selected rect in AppKit global coordinates.
    let globalRect: CGRect
}

/// Area mode (CS-3, CS-4): dims every display, lets the user drag a rectangle on one of
/// them, adjust it with handles, then press Return / Record to start or Esc to cancel.
@MainActor
final class AreaSelectionController {
    private var panels: [OverlayPanel] = []
    private var views: [AreaSelectionView] = []
    private var continuation: CheckedContinuation<AreaSelection?, Never>?

    func run() async -> AreaSelection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            show()
        }
    }

    private func show() {
        let mouseScreen = NSScreen.withMouse
        for screen in NSScreen.screens {
            let panel = OverlayPanel(screen: screen)
            let view = AreaSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onBeginSelection = { [weak self, weak view] in
                self?.views.forEach { if $0 !== view { $0.clearSelection() } }
            }
            let screenFrame = screen.frame
            let displayID = screen.displayID ?? CGMainDisplayID()
            view.onConfirm = { [weak self] localRect in
                let global = localRect.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY)
                self?.finish(AreaSelection(displayID: displayID, screenFrame: screenFrame, globalRect: global))
            }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panel.orderFrontRegardless()
            if screen == mouseScreen || (mouseScreen == nil && screen == NSScreen.screens.first) {
                panel.makeKey()
                panel.makeFirstResponder(view)
            }
            panels.append(panel)
            views.append(view)
        }
        NSApp.activate()
    }

    private func finish(_ result: AreaSelection?) {
        guard let continuation else { return }
        self.continuation = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        continuation.resume(returning: result)
    }
}

final class AreaSelectionView: NSView {
    var onBeginSelection: (() -> Void)?
    var onConfirm: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private enum Drag {
        case none
        case creating(origin: CGPoint)
        case moving(grab: CGPoint, original: CGRect)
        case resizing(edges: ResizeEdges)
    }

    private static let minimumSize: CGFloat = 16
    private static let handleSize: CGFloat = 8

    private var selection: CGRect?
    private var drag: Drag = .none
    private var cursorPoint: CGPoint?
    private lazy var controlBar = AreaControlBar(
        onRecord: { [weak self] in self?.confirm() },
        onCancel: { [weak self] in self?.onCancel?() }
    )

    override init(frame: NSRect) {
        super.init(frame: frame)
        controlBar.isHidden = true
        addSubview(controlBar)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Area selection. Drag to select an area, press Return to record, Escape to cancel.")
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

    func clearSelection() {
        selection = nil
        drag = .none
        controlBar.isHidden = true
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        if let selection, let edges = handle(at: p, for: selection) {
            drag = .resizing(edges: edges)
        } else if let selection, selection.contains(p) {
            drag = .moving(grab: p, original: selection)
        } else {
            drag = .creating(origin: p)
            selection = nil
            onBeginSelection?()
        }
        controlBar.isHidden = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        cursorPoint = p
        switch drag {
        case .none:
            return
        case .creating(let origin):
            selection = Geometry.rect(from: origin, to: p).integral
        case .moving(let grab, let original):
            let moved = original.offsetBy(dx: (p.x - grab.x).rounded(), dy: (p.y - grab.y).rounded())
            selection = Geometry.keep(moved, inside: bounds)
        case .resizing(let edges):
            if let current = selection {
                selection = Geometry.resize(current, edges: edges, to: p).integral
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let selection, selection.width < Self.minimumSize || selection.height < Self.minimumSize {
            if case .creating = drag {
                self.selection = nil
            } else {
                self.selection = CGRect(
                    origin: selection.origin,
                    size: CGSize(width: max(selection.width, Self.minimumSize), height: max(selection.height, Self.minimumSize))
                )
            }
        }
        drag = .none
        layoutControlBar()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        cursorPoint = convert(event.locationInWindow, from: nil)
        updateCursor()
        if selection == nil { needsDisplay = true }
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor()
    }

    private func updateCursor() {
        guard let p = cursorPoint else { return NSCursor.crosshair.set() }
        if let selection, let edges = handle(at: p, for: selection) {
            Self.cursor(for: edges).set()
        } else if let selection, selection.contains(p) {
            NSCursor.openHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    private static func cursor(for edges: ResizeEdges) -> NSCursor {
        let position: NSCursor.FrameResizePosition
        switch edges {
        case [.left, .bottom]: position = .bottomLeft
        case [.right, .bottom]: position = .bottomRight
        case [.left, .top]: position = .topLeft
        case [.right, .top]: position = .topRight
        case .left: position = .left
        case .right: position = .right
        case .top: position = .top
        default: position = .bottom
        }
        return NSCursor.frameResize(position: position, directions: .all)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case OverlayKey.escape: onCancel?()
        case OverlayKey.returnKey, OverlayKey.enter: confirm()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    private func confirm() {
        guard let selection, case .none = drag else { return }
        onConfirm?(selection)
    }

    // MARK: - Geometry helpers

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    private func handleRect(_ edges: ResizeEdges, for r: CGRect) -> CGRect {
        let x = edges.contains(.left) ? r.minX : edges.contains(.right) ? r.maxX : r.midX
        let y = edges.contains(.bottom) ? r.minY : edges.contains(.top) ? r.maxY : r.midY
        let s = Self.handleSize
        return CGRect(x: x - s / 2, y: y - s / 2, width: s, height: s)
    }

    private func handle(at p: CGPoint, for r: CGRect) -> ResizeEdges? {
        ResizeEdges.allHandles.first { handleRect($0, for: r).insetBy(dx: -4, dy: -4).contains(p) }
    }

    private func layoutControlBar() {
        guard let selection else {
            controlBar.isHidden = true
            return
        }
        let size = controlBar.fittingSize
        var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.minY - size.height - 12)
        if origin.y < bounds.minY + 8 {
            origin.y = selection.maxY + 12 // no room below: place it above
            if origin.y + size.height > bounds.maxY - 8 {
                origin.y = selection.minY + 12 // no room either side: inside the rect
            }
        }
        origin.x = min(max(origin.x, bounds.minX + 8), bounds.maxX - size.width - 8)
        controlBar.frame = CGRect(origin: origin, size: size).integral
        controlBar.isHidden = false
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.35).setFill()
        bounds.fill()

        guard let selection else {
            OverlayLabel.draw(
                "Drag to select an area · Esc to cancel",
                centeredAt: CGPoint(x: bounds.midX, y: bounds.midY),
                in: bounds,
                fontSize: 15
            )
            return
        }

        NSColor.clear.setFill()
        selection.fill(using: .copy)

        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor.white.setStroke()
        border.stroke()
        border.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        border.stroke()

        if case .creating = drag {} else {
            for edges in ResizeEdges.allHandles {
                let r = handleRect(edges, for: selection)
                NSColor.white.setFill()
                r.fill()
                NSColor.black.withAlphaComponent(0.6).setStroke()
                NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }

        let label = "\(Int(selection.width)) × \(Int(selection.height))"
        if case .none = drag {
            OverlayLabel.draw(label, origin: CGPoint(x: selection.minX, y: selection.maxY + 6), in: bounds)
        } else {
            let anchor = cursorPoint ?? CGPoint(x: selection.maxX, y: selection.minY)
            OverlayLabel.draw(label, origin: CGPoint(x: anchor.x + 12, y: anchor.y - 28), in: bounds)
        }
    }
}

/// Floating bar under the selection: frame rate, cursor toggle, Cancel and Record.
final class AreaControlBar: NSVisualEffectView {
    private let onRecord: () -> Void
    private let onCancel: () -> Void
    private let fpsPopup = NSPopUpButton()
    private let cursorCheckbox = NSButton(checkboxWithTitle: "Cursor", target: nil, action: nil)

    init(onRecord: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onRecord = onRecord
        self.onCancel = onCancel
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        appearance = NSAppearance(named: .vibrantDark)

        let settings = RecordingSettings(defaults: .standard)
        for rate in FrameRate.allCases {
            fpsPopup.addItem(withTitle: "\(rate.rawValue) fps")
            fpsPopup.lastItem?.tag = rate.rawValue
        }
        fpsPopup.selectItem(withTag: settings.frameRate.rawValue)
        fpsPopup.target = self
        fpsPopup.action = #selector(fpsChanged)
        fpsPopup.setAccessibilityLabel("Frame rate")

        cursorCheckbox.state = settings.showsCursor ? .on : .off
        cursorCheckbox.target = self
        cursorCheckbox.action = #selector(cursorChanged)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        let record = NSButton(title: "Record", target: self, action: #selector(recordClicked))
        record.keyEquivalent = "\r"
        record.bezelColor = .systemRed

        let stack = NSStackView(views: [fpsPopup, cursorCheckbox, cancel, record])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fpsChanged() {
        UserDefaults.standard.set(fpsPopup.selectedTag(), forKey: PreferenceKey.frameRate)
    }

    @objc private func cursorChanged() {
        UserDefaults.standard.set(cursorCheckbox.state == .on, forKey: PreferenceKey.showsCursor)
    }

    @objc private func recordClicked() { onRecord() }
    @objc private func cancelClicked() { onCancel() }
}
