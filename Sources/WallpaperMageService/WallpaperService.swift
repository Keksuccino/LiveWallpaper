import AppKit
import Core

// Draws one wallpaper on one display. The DisplayPlayer makes one for every wallpaper it shows, so the next one can
// load and come in while the current one still plays.

@MainActor class WallpaperService {
    /// The display's UUID (NSScreen.displayID).
    let displayID: String
    /// The item could not be shown (user-facing reason, nil = no detail). The DisplayPlayer moves on.
    var onFailure: (@MainActor (VideoItem, String?) -> Void)?
    /// The item is on screen in the (still transparent) window: its first frame is drawn. Fired once per start; the
    /// DisplayPlayer then brings the window in.
    var onReady: (@MainActor (VideoItem) -> Void)?
    private(set) var item: VideoItem?
    /// The library and settings as last given (`update`).
    private(set) var state = LibraryState()
    private var readyReported = false
    private var readyFallback: Task<Void, Never>?

    init(displayID: String) {
        self.displayID = displayID
    }

    /// The window the wallpaper is drawn in, for transitions; nil while there is none.
    var surface: TransitionWindow? { nil }

    /// The item's options on this display: its playlist's while the display plays one that has it.
    var options: WallpaperOptions? { item.map { state.options(for: $0.id, on: displayID) } }

    /// The settings or the library changed.
    func update(_ state: LibraryState) { self.state = state }

    func start(_ item: VideoItem) {
        self.item = item
        readyReported = false
        readyFallback?.cancel()
        readyFallback = nil
    }

    func stop() {
        item = nil
        readyFallback?.cancel()
        readyFallback = nil
    }

    func setPaused(_ paused: Bool) {}
    func setScreenLocked(_ locked: Bool) {}
    /// A new system wallpaper was set under the window (DisplayWindow.revealSystemWallpaper).
    func revealSystemWallpaper() {}

    /// Fires `onReady` for the current item, once.
    func reportReady() {
        guard let item, !readyReported else { return }
        readyReported = true
        readyFallback?.cancel()
        readyFallback = nil
        onReady?(item)
    }

    /// The item counts as ready after `seconds` even if its first frame never comes, so a window cannot stay
    /// transparent for good.
    func reportReady(after seconds: Double) {
        readyFallback?.cancel()
        let nanoseconds = UInt64(seconds * 1_000_000_000)
        readyFallback = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            self?.reportReady()
        }
    }
}

/// Videos through an AVPlayer window.
@MainActor final class VideoRenderService: WallpaperService {
    /// A video whose first frame takes longer than this (a slow disk) is shown anyway.
    private static let readyTimeout = 3.0
    private let windows: WallpaperWindowManager

    override init(displayID: String) {
        windows = WallpaperWindowManager(displayID: displayID)
        super.init(displayID: displayID)
        windows.onPlaybackFailure = { [weak self] url in
            guard let self, let item = self.item, item.url == url else { return }
            self.onFailure?(item, String(localized: "Couldn’t play “\(item.name)”."))
        }
        windows.onReady = { [weak self] in self?.reportReady() }
    }

    override var surface: TransitionWindow? { windows.surface }

    /// The settings changed: the video follows its wallpaper options and the master volume.
    override func update(_ state: LibraryState) {
        super.update(state)
        applyOptions()
    }

    override func start(_ item: VideoItem) {
        super.start(item)
        windows.show(url: item.url)
        applyOptions()
        reportReady(after: Self.readyTimeout)
    }

    private func applyOptions() {
        guard let options else { return }
        windows.apply(options, masterVolume: state.masterVolume, appMuted: state.muted)
    }

    override func stop() {
        super.stop()
        windows.hide()
    }

    override func setPaused(_ paused: Bool) { windows.setPaused(paused) }
    override func setScreenLocked(_ locked: Bool) { windows.setScreenLocked(locked) }
    override func revealSystemWallpaper() { windows.revealSystemWallpaper() }
}
