import AppKit
import ObjectiveC

/// UI testing without disturbing the screen (TESTING_GUIDELINES.md): launched with `WM_OFFSCREEN=1` in its environment,
/// the app moves every titled window past the right edge of the displays as soon as it shows, all but one point
/// column, so per-window screenshots and accessibility actions can drive it while nothing noticeable appears on screen.
/// It never activates itself either way.
@MainActor
enum OffscreenTesting {
    static var isOn: Bool { ProcessInfo.processInfo.environment["WM_OFFSCREEN"] == "1" }
    private static var observer: NSObjectProtocol?
    private static var moved: Set<Int> = []

    static func start() {
        guard isOn, observer == nil else { return }
        allowFramesOffScreen()
        // After every pass of the event loop, so a window is moved before the window server first draws it on screen.
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { moveWindowsAway() }
        }
    }

    /// AppKit keeps a part of every window on a display (`constrainFrameRect(_:to:)`, which it calls whenever a frame
    /// changes) and slides a popover into a display's visible area. Replacing NSWindow's implementation with one that
    /// keeps the frame as it is lets both stay wherever their window or anchor is. Test runs only: never call it
    /// otherwise, as it changes every window of the process.
    private static func allowFramesOffScreen() {
        guard let method = class_getInstanceMethod(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:))) else {
            return
        }
        let keep: @convention(block) (NSWindow, NSRect, NSScreen?) -> NSRect = { _, frame, _ in frame }
        method_setImplementation(method, imp_implementationWithBlock(keep))
    }

    /// Moves each titled window once, the first time it shows, so that a single point column of it stays on the
    /// rightmost display: the window server draws (and lets capture) only windows that are on a display at least in
    /// part, and one point at a display's edge goes unnoticed.
    private static func moveWindowsAway() {
        guard let screen = NSScreen.screens.max(by: { $0.frame.maxX < $1.frame.maxX }) else { return }
        for window in NSApp.windows where window.styleMask.contains(.titled) && window.isVisible
            && !moved.contains(window.windowNumber) {
            moved.insert(window.windowNumber)
            // Without its autosave name the window no longer saves its frame, so the next normal launch opens where
            // the user left it, not off-screen.
            window.setFrameAutosaveName("")
            window.setFrameOrigin(NSPoint(x: screen.frame.maxX - 1, y: screen.frame.minY))
        }
    }
}
