import AppKit
import Core

// The window a wallpaper is drawn in on one display, just above Apple's wallpaper. Videos and scenes both use it.
// The window, and the view and layer in it, stay for as long as the display stays connected: a change of the screen
// parameters (resolution, arrangement, the menu bar's background) only moves or resizes the window, so a layer a
// renderer draws into is never swapped out from under it.
// A window opens transparent, so the wallpaper it replaces stays visible under it while its own loads; it turns opaque
// when it is presented, at once or at the end of a transition (WallpaperTransition).

/// A borderless window that keeps its full screen frame. AppKit otherwise shrinks it to the visible frame, which
/// leaves a strip under the menu bar undrawn.
private final class FullFrameWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// The window's content view: the view a renderer or player draws into, inside a stage that transitions fade, move
/// and blur. Only the stage's layer is animated; the view's own layer belongs to AppKit and the renderer.
final class StageView: NSView {
    let content: NSView

    init(content: NSView) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true  // contentFilters, for the blur transition
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// What a transition needs of a wallpaper's window, whatever view the window holds.
@MainActor protocol TransitionWindow: AnyObject {
    var window: NSWindow? { get }
    var stage: StageView? { get }
    /// A transition animates the window: the system wallpaper is let through only after it (revealSystemWallpaper).
    var isTransitioning: Bool { get set }
    /// The wallpaper in the window is ready: the window turns opaque and shows it fully.
    func present()
}

/// One desktop-level window on one display, with a `View` as its content view.
@MainActor final class DisplayWindow<View: NSView>: TransitionWindow {
    /// The display's UUID (NSScreen.displayID).
    let displayID: String
    /// Called after the window followed a change of its screen: moved, resized, or gone with the screen.
    var onChange: (() -> Void)?
    private(set) var window: NSWindow?
    private(set) var view: View?
    private(set) var stage: StageView?
    /// Opaque and fully visible; before, the window is transparent and whatever it replaces shows through.
    private(set) var isPresented = false
    var isTransitioning = false {
        didSet { if !isTransitioning, revealPending { revealSystemWallpaper() } }
    }
    private let makeView: () -> View
    private var observer: NSObjectProtocol?
    private var reveal: Task<Void, Never>?
    private var revealPending = false

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
        revealPending = false
        isTransitioning = false
        isPresented = false
        closeWindow()
    }

    func present() {
        isPresented = true
        applyPresentation()
        if revealPending, !isTransitioning { revealSystemWallpaper() }
    }

    /// Makes macOS draw the system wallpaper under the window once, so the menu bar's background picks up a
    /// wallpaper that was just set. The menu bar keeps its own copy of the wallpaper and refreshes it only when the
    /// wallpaper is actually composited, which never happens while this opaque window covers it completely: a new
    /// wallpaper would reach the menu bar only when something else uncovers the desktop. Letting the wallpaper show
    /// through at 1% for half a second is enough (measured: the menu bar follows within about 0.7 s, even when this
    /// starts right after the wallpaper was set). The wallpaper is a still of what the window shows, so the blend is
    /// invisible. Ordering the window out and in works too, but flashes.
    /// A window that is not presented yet, or is in a transition, keeps the request and lets the wallpaper through
    /// once it is presented and the transition is over: the window it replaces, which would let it through meanwhile,
    /// closes at the end of the transition, so a still set during a transition would otherwise never reach the menu
    /// bar.
    func revealSystemWallpaper() {
        guard let window else { return }
        guard isPresented, !isTransitioning else {
            revealPending = true
            return
        }
        revealPending = false
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
        let stage = StageView(content: view)
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
        window.contentView = stage
        self.window = window
        self.view = view
        self.stage = stage
        applyPresentation()
        window.orderFrontRegardless()
    }

    /// Presented: opaque and black behind the wallpaper. Before: transparent, the stage hidden.
    private func applyPresentation() {
        guard let window, let stage else { return }
        window.isOpaque = isPresented
        window.backgroundColor = isPresented ? .black : .clear
        stage.alphaValue = isPresented ? 1 : 0
    }

    private func closeWindow() {
        window?.close()
        window = nil
        view = nil
        stage = nil
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
