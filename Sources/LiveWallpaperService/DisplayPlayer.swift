import AppKit
import Core

// Shows the wallpaper of one display: the one set for it, or, while it rotates, the playlist in turn from there.
// A rotating display skips items that cannot play; any other display shows nothing live then and reports why. The
// Orchestrator owns one per connected display that has a wallpaper.

@MainActor final class DisplayPlayer {
    private static let nothingPlayable = "None of the wallpapers in your playlist can be played."

    /// The display's UUID (NSScreen.displayID).
    let displayID: String
    /// Fired after `current` or `error` changed outside of a call from the Orchestrator (a failure, a rotation).
    var onChange: (@MainActor () -> Void)?
    /// What the display shows; nil when nothing could be shown.
    private(set) var current: UUID?
    /// Why the wallpaper could not be shown (user-facing); cleared when another one is set.
    private(set) var error: String?

    private var state: LibraryState
    private var config: DisplayConfig { state.config(for: displayID) }
    private let video: VideoRenderService
    private let scene: SceneRenderService
    private var failedIDs: Set<UUID> = []
    private var rotationTimer: Timer?
    private var paused: Bool
    private var showDepth = 0  // > 0 while show() runs: a render service may report a failure synchronously

    init(displayID: String, state: LibraryState, paused: Bool) {
        self.displayID = displayID
        self.state = state
        self.paused = paused
        video = VideoRenderService(displayID: displayID)
        scene = SceneRenderService(displayID: displayID)
        // The scene is on screen: the previous (video) wallpaper can go.
        scene.onReady = { [weak self] _ in self?.video.stop() }
        for service in [video, scene] as [WallpaperService] {
            service.onFailure = { [weak self] item, message in self?.failed(item, message) }
            service.setMuted(config.muted)
        }
        scene.update(state)
        showWallpaper()
    }

    var currentItem: VideoItem? { state.item(current) }
    var rotates: Bool { state.rotates(displayID) }

    // MARK: Changes

    /// New settings or library. A different wallpaper is shown at once; rotation goes on from it.
    func update(_ fresh: LibraryState) {
        let old = state
        let oldConfig = config
        state = fresh  // first, so the reads below see the new values
        failedIDs.formIntersection(fresh.videos.map(\.id))
        if config.muted != oldConfig.muted {
            video.setMuted(config.muted)
            scene.setMuted(config.muted)
        }
        scene.update(fresh)  // diffs itself; no restart
        if config.wallpaperID != oldConfig.wallpaperID {
            showWallpaper()
        } else if let current, fresh.item(current) == nil {
            // The item on screen left the library (a rotation item; the wallpaper itself would have changed above).
            advance(after: current, in: old)
        }
        if rotates != old.rotates(displayID) || config.intervalSeconds != oldConfig.intervalSeconds {
            scheduleRotation()
        }
    }

    /// Moves on to the next playlist item while the display rotates.
    func next() {
        guard rotates, let current else { return }
        advance(after: current, in: state)
    }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        video.setPaused(paused)
        scene.setPaused(paused)
        scheduleRotation()
    }

    func setScreenLocked(_ locked: Bool) {
        video.setScreenLocked(locked)
        scene.setScreenLocked(locked)
    }

    func revealSystemWallpaper() {
        video.revealSystemWallpaper()
        scene.revealSystemWallpaper()
    }

    /// Takes everything off the display.
    func stop() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        current = nil
        video.stop()
        scene.stop()
    }

    // MARK: Showing

    /// Shows the wallpaper set for the display, asking for it by name being worth another try.
    private func showWallpaper() {
        error = nil
        guard let id = config.wallpaperID, let item = state.item(id) else {
            clear()
            return
        }
        failedIDs.remove(id)
        if playable(item) {
            show(item)
        } else if rotates {
            advance(after: id, in: state)
        } else {
            clear()
            error = "Couldn’t find “\(item.name)”. It may have been moved or deleted."
        }
        scheduleRotation()
    }

    /// Shows the first playable playlist item after `id` (wrapping), or nothing. `list` is the state `id` was
    /// shown from: when it has left the playlist since, its place there tells where to go on.
    private func advance(after id: UUID, in list: LibraryState) {
        let items = state.playlistItems
        let start = Self.index(after: id, in: list.playlist ?? [], within: items.map(\.id))
        for offset in 0..<items.count {
            let item = items[(start + offset) % items.count]
            if playable(item) {
                show(item)
                scheduleRotation()
                return
            }
        }
        clear()
        error = error ?? Self.nothingPlayable
    }

    /// The index in `now` of the first item that follows `id` in `before` and is still there; 0 without one.
    private static func index(after id: UUID, in before: [UUID], within now: [UUID]) -> Int {
        guard let position = before.firstIndex(of: id) else { return 0 }
        for later in before[(position + 1)...] + before[..<position] {
            if let index = now.firstIndex(of: later) { return index }
        }
        return 0
    }

    /// Not failed before, and the file is there (a missing file counts as failed from now on).
    private func playable(_ item: VideoItem) -> Bool {
        guard !failedIDs.contains(item.id) else { return false }
        if FileManager.default.fileExists(atPath: item.path) { return true }
        failedIDs.insert(item.id)
        return false
    }

    private func show(_ item: VideoItem) {
        guard item.id != current else { return }  // the item that is already showing is left alone
        current = item.id
        showDepth += 1
        defer { showDepth -= 1 }
        if item.isScene {
            // The video window stays up (previous wallpaper) until the scene renderer shows its first frame.
            scene.update(state)
            scene.start(item)
            if scene.item?.id == item.id { scene.setPaused(paused) }
        } else {
            scene.stop()
            video.start(item)
            video.setPaused(paused)
        }
    }

    private func clear() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard current != nil else { return }
        current = nil
        video.stop()
        scene.stop()
    }

    // From a render service: only the item currently on the display counts.
    private func failed(_ item: VideoItem, _ message: String?) {
        guard item.id == current else { return }
        failedIDs.insert(item.id)
        if rotates {
            advance(after: item.id, in: state)
        } else {
            clear()
        }
        error = message ?? "Couldn’t show “\(item.name)”."
        if showDepth == 0 { onChange?() }  // inside show() the caller reports the change itself
    }

    private func scheduleRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard !paused, current != nil, rotates else { return }
        let interval = config.intervalSeconds
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.next()
                self?.onChange?()
            }
        }
        timer.tolerance = min(interval * 0.1, 5)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }
}
