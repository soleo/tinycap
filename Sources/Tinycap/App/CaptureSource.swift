import AppKit
import ScreenCaptureKit
import TinycapCore

/// When a capture started and what it showed, for the `{date}`, `{app}` and `{window}`
/// filename tokens (EX-12).
struct CaptureSource {
    var date = Date()
    var app: String?
    var window: String?

    /// A window capture names its own app and title. A screen or area capture names the
    /// frontmost normal window's app inside it, and no window.
    @MainActor
    static func describe(_ target: CaptureTarget) -> CaptureSource {
        switch target {
        case .window(let window), .windowRegion(let window, _, _):
            let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return CaptureSource(app: window.owningApplication?.applicationName,
                                 window: title?.isEmpty == false ? title : nil)
        case .display(let display):
            return CaptureSource(app: frontmostApp(in: display.frame))
        case .area(let display, let rect):
            return CaptureSource(app: frontmostApp(in: rect.offsetBy(dx: display.frame.minX, dy: display.frame.minY)))
        }
    }

    /// `rect` is in global, top-left-origin points, as Core Graphics window bounds are.
    /// The window list comes front to back.
    private static func frontmostApp(in rect: CGRect) -> String? {
        let ownPID = Int(ProcessInfo.processInfo.processIdentifier)
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for info in windows {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.intersects(rect),
                  let name = info[kCGWindowOwnerName as String] as? String, !name.isEmpty
            else { continue }
            return name
        }
        return nil
    }

    func context(_ kind: FilenameContext.Kind, counter: Int) -> FilenameContext {
        FilenameContext(kind: kind, date: date, app: app, window: window, counter: counter)
    }
}
