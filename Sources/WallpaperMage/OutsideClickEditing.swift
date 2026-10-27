import SwiftUI
import AppKit

// A click outside the text field being edited ends its editing, in every window of the app (sheets and alerts too).
// AppKit keeps a text field editing until another view takes focus, so without this a click on empty space, a plain
// button or a list would leave the caret in the field and the keyboard going to it. One local event monitor,
// installed at launch, covers every text field; a field needs nothing of its own unless it draws padding, an icon or
// buttons around itself (`textFieldClickArea()`).

/// Ends text editing when a mouse-down lands outside the edited field. It acts before AppKit delivers the click and
/// passes the event on unchanged, so the click still reaches its target, which may take focus in turn (another field).
@MainActor
enum OutsideClickEditing {
    private static var monitor: Any?
    /// The live `textFieldClickArea()` markers that are in a window.
    fileprivate static let areas = NSHashTable<NSView>.weakObjects()

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            endEditingIfOutside(event)
            return event
        }
    }

    private static func endEditingIfOutside(_ event: NSEvent) {
        guard let window = event.window, let editor = window.firstResponder as? NSTextView, editor.isEditable else { return }
        // A text field edits through its window's shared field editor, whose delegate is the field; a multi-line text
        // view edits itself, inside its scroll view.
        let field: NSView = editor.isFieldEditor ? (editor.delegate as? NSView ?? editor) : (editor.enclosingScrollView ?? editor)
        let frame = field.convert(field.bounds, to: nil)
        let point = event.locationInWindow
        guard !frame.contains(point), !inClickArea(point, of: frame, in: window) else { return }
        window.makeFirstResponder(nil)
    }

    /// Whether `point` lies in the click area of the field at `frame`: a marker in the same window that holds both the
    /// point and the field's centre (a marker around another field does not count).
    private static func inClickArea(_ point: NSPoint, of frame: NSRect, in window: NSWindow) -> Bool {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        return areas.allObjects.contains { area in
            guard area.window === window else { return false }
            let areaFrame = area.convert(area.bounds, to: nil)
            return areaFrame.contains(point) && areaFrame.contains(center)
        }
    }
}

extension View {
    /// Clicks anywhere in this view count as clicks on the text field inside it, so they do not end its editing. For a
    /// field drawn with padding, an icon or buttons around it: a search bar's clear button leaves the field editing.
    func textFieldClickArea() -> some View {
        background(TextFieldClickArea())
    }
}

/// The marker behind a `textFieldClickArea()`: registered with OutsideClickEditing while it is in a window, and never
/// part of hit-testing, so it takes no clicks from the views it lies behind.
private struct TextFieldClickArea: NSViewRepresentable {
    func makeNSView(context: Context) -> AreaView { AreaView() }

    func updateNSView(_ view: AreaView, context: Context) {}

    final class AreaView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil {
                OutsideClickEditing.areas.add(self)
            } else {
                OutsideClickEditing.areas.remove(self)
            }
        }
    }
}
