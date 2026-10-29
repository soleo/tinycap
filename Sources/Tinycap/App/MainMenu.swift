import AppKit

/// Tinycap is a menu-bar app, so this menu is never shown. It exists so the standard
/// shortcuts (⌘C, ⌘V, ⌘Z, ⌘S, ⌘W, ⌘A) reach the focused window through the responder
/// chain: text fields get copy and paste, and the screenshot editor gets its commands.
enum MainMenu {
    @MainActor
    static func install() {
        let main = NSMenu()

        let app = NSMenu(title: "Tinycap")
        app.addItem(withTitle: "Quit Tinycap", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Save", action: #selector(ScreenshotEditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: file)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(ScreenshotEditorWindowController.undo(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: #selector(ScreenshotEditorWindowController.redo(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit)

        NSApp.mainMenu = main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
