import AppKit

// The windows a wallpaper is drawn in, one per screen, just above Apple's wallpaper. Videos and scenes both use
// them. A screen keeps its window, and the view and layer in it, for as long as it stays connected: a change of the
// screen parameters (resolution, arrangement, the menu bar's background) only moves or resizes the windows, so a
// layer a renderer draws into is never swapped out from under it.

/// A borderless window that keeps its full screen frame. AppKit otherwise shrinks it to the visible frame, which
/// leaves a strip under the menu bar undrawn.
private final class DesktopWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// One desktop-level window per screen, each with a `View` as its content view.
@MainActor final class DesktopWindows<View: NSView> {
    struct Entry {
        /// Stable id of the screen (its display number).
        let id: String
        let window: NSWindow
        let view: View
    }

    /// Called after the windows followed a change of the screens (connected, removed, moved or resized).
    var onChange: (() -> Void)?
    private(set) var entries: [Entry] = []
    private let makeView: () -> View
    private var observer: NSObjectProtocol?
    private var reveal: Task<Void, Never>?

    init(makeView: @escaping () -> View) {
        self.makeView = makeView
    }

    var isOpen: Bool { !entries.isEmpty }

    /// Creates the windows unless they are open already.
    func open() {
        guard !isOpen else { return }
        sync()
        observeScreens()
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        reveal?.cancel()
        reveal = nil
        entries.forEach { $0.window.close() }
        entries.removeAll()
    }

    /// Makes macOS draw the system wallpaper under the windows once, so the menu bar's background picks up a
    /// wallpaper that was just set. The menu bar keeps its own copy of the wallpaper and refreshes it only when the
    /// wallpaper is actually composited, which never happens while these opaque windows cover it completely: a new
    /// wallpaper would reach the menu bar only when something else uncovers the desktop. Letting the wallpaper show
    /// through at 1% for half a second is enough (measured: the menu bar follows within about 0.7 s, even when this
    /// starts right after the wallpaper was set). The wallpaper is a still of what the windows show, so the blend is
    /// invisible. Ordering the windows out and in works too, but flashes.
    func revealSystemWallpaper() {
        guard isOpen else { return }
        entries.forEach { $0.window.alphaValue = 0.99 }
        reveal?.cancel()
        reveal = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            self?.entries.forEach { $0.window.alphaValue = 1 }
            self?.reveal = nil
        }
    }

    /// Keeps the window of every screen that is still connected, makes windows for new screens and closes the rest.
    private func sync() {
        var kept: [Entry] = []
        for screen in NSScreen.screens {
            let id = screen.displayID
            if let entry = entries.first(where: { $0.id == id }) {
                if entry.window.frame != screen.frame { entry.window.setFrame(screen.frame, display: false) }
                kept.append(entry)
            } else {
                kept.append(makeEntry(id: id, on: screen))
            }
        }
        for entry in entries where !kept.contains(where: { $0.id == entry.id }) { entry.window.close() }
        entries = kept
    }

    private func makeEntry(id: String, on screen: NSScreen) -> Entry {
        let view = makeView()
        let window = DesktopWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.isReleasedWhenClosed = false  // ARC owns the window; the default would over-release on close()
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.canHide = false
        window.isExcludedFromWindowsMenu = true
        window.backgroundColor = .black
        window.contentView = view
        window.orderFrontRegardless()
        return Entry(id: id, window: window, view: view)
    }

    private func observeScreens() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isOpen else { return }
                self.sync()
                self.onChange?()
            }
        }
    }
}

extension NSScreen {
    /// The screen's number, which is stable while the display is connected.
    var displayID: String {
        let number = (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0
        return String(number)
    }
}
