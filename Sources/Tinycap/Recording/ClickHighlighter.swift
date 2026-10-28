import AppKit
import QuartzCore

/// Draws a ring at each mouse click (RC-4) in a click-through window over one screen.
/// Tinycap's own windows are excluded from capture, so the recorder lists this window
/// as an exception to get the rings into the video.
///
/// Watching clicks in other apps uses a global mouse monitor, which needs no extra
/// permission (only key monitoring does).
@MainActor
final class ClickHighlighter {
    private let panel: ClickPanel
    private var monitors: [Any] = []

    /// The overlay's window number, used to find it in `SCShareableContent`.
    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init(screen: NSScreen) {
        panel = ClickPanel(frame: screen.frame)
    }

    func start() {
        panel.orderFrontRegardless()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.ring(at: NSEvent.mouseLocation) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            self?.ring(at: NSEvent.mouseLocation)
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
    }

    private func ring(at globalPoint: CGPoint) {
        guard panel.frame.contains(globalPoint), let layer = panel.contentView?.layer else { return }
        let point = CGPoint(x: globalPoint.x - panel.frame.minX, y: globalPoint.y - panel.frame.minY)
        let diameter: CGFloat = 44

        let ring = CAShapeLayer()
        ring.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        ring.position = point
        ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 2, dy: 2), transform: nil)
        ring.fillColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
        ring.strokeColor = NSColor.systemYellow.cgColor
        ring.lineWidth = 3
        ring.opacity = 0
        layer.addSublayer(ring)

        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.4
        scale.toValue = 1.2
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, 0.5, 1]
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.45
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)

        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(group, forKey: "click")
        CATransaction.commit()
    }
}

private final class ClickPanel: NSPanel {
    init(frame: CGRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        sharingType = .readOnly
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = NSView(frame: CGRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        contentView = view
    }

    override var canBecomeKey: Bool { false }
}
