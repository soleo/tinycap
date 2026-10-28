import AppKit
import SwiftUI

/// Shows THIRD_PARTY_NOTICES.md from the app bundle (libvpx and libwebm licenses).
@MainActor
final class AcknowledgementsWindowController {
    static let shared = AcknowledgementsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AcknowledgementsView()))
            window.title = "Acknowledgements"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 620, height: 520))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AcknowledgementsView: View {
    private let text: String = {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "Tinycap uses libvpx and libwebm from the WebM Project (BSD-3-Clause)." }
        return text.replacingOccurrences(of: "```\n", with: "")
    }()

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
        }
        .frame(minWidth: 480, minHeight: 360)
    }
}
