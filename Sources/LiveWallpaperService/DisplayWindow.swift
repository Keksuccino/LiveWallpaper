import AppKit
import Core

// The window a wallpaper is drawn in on one display, just above Apple's wallpaper. Videos and scenes both use it.
// The window, and the view and layer in it, stay for as long as the display stays connected: a change of the screen
// parameters (resolution, arrangement, the menu bar's background) only moves or resizes the window, so a layer a
// renderer draws into is never swapped out from under it.

/// A borderless window that keeps its full screen frame. AppKit otherwise shrinks it to the visible frame, which
/// leaves a strip under the menu bar undrawn.
private final class FullFrameWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// One desktop-level window on one display, with a `View` as its content view.
@MainActor final class DisplayWindow<View: NSView> {
    /// The display's UUID (NSScreen.displayID).
    let displayID: String
    /// Called after the window followed a change of its screen: moved, resized, or gone with the screen.
    var onChange: (() -> Void)?
    private(set) var window: NSWindow?
    private(set) var view: View?
    private let makeView: () -> View
    private var observer: NSObjectProtocol?
    private var reveal: Task<Void, Never>?

    init(displayID: String, makeView: @escaping () -> View) {
        self.displayID = displayID
        self.makeView = makeView
    }

    /// Open: the window is shown whenever its screen is connected.
    var isOpen: Bool { observer != nil }

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
        closeWindow()
    }

    /// Makes macOS draw the system wallpaper under the window once, so the menu bar's background picks up a
    /// wallpaper that was just set. The menu bar keeps its own copy of the wallpaper and refreshes it only when the
    /// wallpaper is actually composited, which never happens while this opaque window covers it completely: a new
    /// wallpaper would reach the menu bar only when something else uncovers the desktop. Letting the wallpaper show
    /// through at 1% for half a second is enough (measured: the menu bar follows within about 0.7 s, even when this
    /// starts right after the wallpaper was set). The wallpaper is a still of what the window shows, so the blend is
    /// invisible. Ordering the window out and in works too, but flashes.
    func revealSystemWallpaper() {
        guard let window else { return }
        window.alphaValue = 0.99
        reveal?.cancel()
        reveal = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
            self?.window?.alphaValue = 1
            self?.reveal = nil
        }
    }

    /// Follows the screen: the window keeps its frame, is made when the screen is connected and closes without it.
    private func sync() {
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            closeWindow()
            return
        }
        if let window {
            if window.frame != screen.frame { window.setFrame(screen.frame, display: false) }
        } else {
            makeWindow(on: screen)
        }
    }

    private func makeWindow(on screen: NSScreen) {
        let view = makeView()
        let window = FullFrameWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered,
                                     defer: false)
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
        self.window = window
        self.view = view
    }

    private func closeWindow() {
        window?.close()
        window = nil
        view = nil
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
    /// The display's UUID (DisplayIdentity): the key of its settings in state.json.
    var displayID: String {
        let number = (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return DisplayIdentity.uuid(of: number)
    }
}
