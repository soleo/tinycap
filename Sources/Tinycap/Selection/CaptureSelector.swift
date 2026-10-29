import AppKit
import ScreenCaptureKit
import TinycapCore

/// Runs the area, window or screen picker and resolves the choice to capture objects.
/// Shared by recording and screenshots (SS-1).
@MainActor
enum CaptureSelector {
    /// What the user picked, plus where to draw the border and the countdown
    /// (both in AppKit global coordinates).
    struct Selection {
        var target: CaptureTarget
        var borderRect: CGRect?
        var countdownRect: CGRect?
    }

    static func select(_ mode: CaptureMode, content: SCShareableContent, purpose: SelectionPurpose) async -> Selection? {
        switch mode {
        case .area:
            guard let selection = await AreaSelectionController(purpose: purpose).run(),
                  let display = content.displays.first(where: { $0.displayID == selection.displayID })
            else { return nil }
            let local = Geometry.displayLocalRect(selection.globalRect, screenFrame: selection.screenFrame)
            return Selection(target: .area(display, rect: local), borderRect: selection.globalRect, countdownRect: selection.globalRect)

        case .window:
            guard let windowID = await WindowPickerController(content: content, purpose: purpose).run(),
                  let window = content.windows.first(where: { $0.windowID == windowID })
            else { return nil }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let frame = Geometry.appKitRect(fromCG: window.frame, primaryScreenHeight: primaryHeight)
            return Selection(target: .window(window), countdownRect: frame)

        case .screen:
            guard let displayID = await ScreenPickerController(purpose: purpose).run(),
                  let display = content.displays.first(where: { $0.displayID == displayID })
            else { return nil }
            let frame = NSScreen.screens.first { $0.displayID == displayID }?.frame
            return Selection(target: .display(display), countdownRect: frame)
        }
    }
}
