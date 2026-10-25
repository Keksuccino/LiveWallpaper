import AppKit
import Core

// Draws a wallpaper on one display. Each DisplayPlayer owns one of each kind and decides which one shows its current
// item.

@MainActor class WallpaperService {
    /// The display's UUID (NSScreen.displayID).
    let displayID: String
    /// The item could not be shown (user-facing reason, nil = no detail). The DisplayPlayer moves on.
    var onFailure: (@MainActor (VideoItem, String?) -> Void)?
    /// The item is on screen. The DisplayPlayer uses it to retire the previous wallpaper.
    var onReady: (@MainActor (VideoItem) -> Void)?
    private(set) var item: VideoItem?

    init(displayID: String) {
        self.displayID = displayID
    }

    func start(_ item: VideoItem) { self.item = item }
    func stop() { item = nil }
    func setPaused(_ paused: Bool) {}
    func setMuted(_ muted: Bool) {}
    func setScreenLocked(_ locked: Bool) {}
    /// A new system wallpaper was set under the window (DisplayWindow.revealSystemWallpaper).
    func revealSystemWallpaper() {}
}

/// Videos through an AVPlayer window.
@MainActor final class VideoRenderService: WallpaperService {
    private let windows: WallpaperWindowManager

    override init(displayID: String) {
        windows = WallpaperWindowManager(displayID: displayID)
        super.init(displayID: displayID)
        windows.onPlaybackFailure = { [weak self] url in
            guard let self, let item = self.item, item.url == url else { return }
            self.onFailure?(item, "Couldn’t play “\(item.name)”.")
        }
    }

    override func start(_ item: VideoItem) {
        super.start(item)
        windows.show(url: item.url)
    }

    override func stop() {
        super.stop()
        windows.hide()
    }

    override func setPaused(_ paused: Bool) { windows.setPaused(paused) }
    override func setMuted(_ muted: Bool) { windows.setMuted(muted) }
    override func setScreenLocked(_ locked: Bool) { windows.setScreenLocked(locked) }
    override func revealSystemWallpaper() { windows.revealSystemWallpaper() }
}
