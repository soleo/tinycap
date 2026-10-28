import AppKit

// Agent app: menu-bar only, no Dock icon (LSUIElement is also set in Info.plist).
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
