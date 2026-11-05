import AppKit
import SwiftUI

/// A file name text field followed by its extension, which isn't editable (EX-10, SX-7).
/// Focusing the field, by click or Tab, selects the whole name so typing replaces it.
struct FileNameField: View {
    @Binding var name: String
    let pathExtension: String
    var width: CGFloat = 220
    /// Focus the field as soon as it appears.
    var autofocus = false
    /// Return in the field.
    var onSubmit: () -> Void = {}
    /// Escape in the field.
    var onCancel: () -> Void = {}
    /// The field gained or lost focus. Views with single-key shortcuts (Space, I, O)
    /// turn them off while it has focus, so typing reaches the field.
    var onFocusChange: (Bool) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 3) {
            SelectAllField(text: $name, autofocus: autofocus, onSubmit: onSubmit, onCancel: onCancel, onFocusChange: onFocusChange)
                .frame(width: width)
                .accessibilityLabel("File name")
            Text(".\(pathExtension)")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .help("File name. The extension follows the format.")
    }
}

private struct SelectAllField: NSViewRepresentable {
    @Binding var text: String
    let autofocus: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeNSView(context: Context) -> FocusSelectingTextField {
        let field = FocusSelectingTextField()
        field.delegate = context.coordinator
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = "File name"
        field.stringValue = text
        field.onFocus = { context.coordinator.parent.onFocusChange(true) }
        if autofocus {
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
        return field
    }

    func updateNSView(_ field: FocusSelectingTextField, context: Context) {
        context.coordinator.parent = self
        // Don't reset the text under the user's caret while they type.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectAllField
        init(_ parent: SelectAllField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            parent.onFocusChange(false)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCancel()
                return true
            }
            return false
        }
    }
}

final class FocusSelectingTextField: NSTextField {
    var onFocus: () -> Void = {}
    private var selectAfterClick = false

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        currentEditor()?.selectAll(nil)
        // A click places the caret when the mouse goes up; select again after that.
        selectAfterClick = NSApp.currentEvent?.type == .leftMouseDown
        onFocus()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if selectAfterClick {
            selectAfterClick = false
            currentEditor()?.selectAll(nil)
        }
    }
}
