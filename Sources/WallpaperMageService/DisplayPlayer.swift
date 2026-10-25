import AppKit
import Core

// Shows what one display is set to: a single wallpaper, or a playlist's wallpapers one after another, each for the
// playlist's interval and brought in with its transition. A playlist skips wallpapers that cannot play; a single
// wallpaper that cannot play leaves the display without a live wallpaper, and the player reports why.
// Every wallpaper gets a render service of its own: the next one loads in a transparent window above the current one,
// which keeps playing until the next one has drawn its first frame and its transition (WallpaperTransition) is over.
// The Orchestrator owns one player per connected display that has content.

@MainActor final class DisplayPlayer {
    private static let nothingPlayable = String(localized: "None of the wallpapers in this playlist can be played.")
    private static let emptyPlaylist = String(localized: "This playlist has no wallpapers yet.")

    /// The display's UUID (NSScreen.displayID).
    let displayID: String
    /// Fired after `current` or `error` changed outside of a call from the Orchestrator (a failure, a rotation).
    var onChange: (@MainActor () -> Void)?
    /// What the display shows, or is about to show once it has loaded; nil when nothing could be shown.
    private(set) var current: UUID?
    /// Why the wallpaper could not be shown (user-facing); cleared when the display is given something else.
    private(set) var error: String?

    private var state: LibraryState
    /// Shows `current`. Its window stays transparent until it is `ready`.
    private var active: WallpaperService?
    private var ready = false
    /// The wallpaper `active` replaces; on screen until `active` is ready and has come in.
    private var outgoing: WallpaperService?
    private var transition: WallpaperTransition?
    /// How `active` comes in once it is ready.
    private var entrance: PlaylistTransition = .cut
    private var entranceDuration = 0.0
    private var failedIDs: Set<UUID> = []
    private var rotationTimer: Timer?
    private var paused: Bool
    private var screenLocked = false
    private var showDepth = 0  // > 0 while show() runs: a render service may report a failure synchronously

    init(displayID: String, state: LibraryState, paused: Bool) {
        self.displayID = displayID
        self.state = state
        self.paused = paused
        start()
    }

    var currentItem: VideoItem? { state.item(current) }
    /// The display plays a playlist of more than one wallpaper.
    var rotates: Bool { lineup.count > 1 && playlist != nil }

    private var content: DisplayContent? { state.config(for: displayID).content }
    private var playlist: Playlist? { state.playlist(on: displayID) }
    private var lineup: [VideoItem] { state.lineup(on: displayID) }

    // MARK: Changes

    /// New settings or library. Other content is shown at once; a playlist that changed goes on from the wallpaper on
    /// screen.
    func update(_ fresh: LibraryState) {
        let oldContent = content
        let oldLineup = lineup.map(\.id)
        let oldInterval = playlist?.intervalSeconds
        let wasRotating = rotates
        state = fresh  // first, so the reads below see the new values
        failedIDs.formIntersection(fresh.videos.map(\.id))
        active?.update(fresh)  // diffs itself; no restart
        outgoing?.update(fresh)
        guard content == oldContent else {
            start()
            return
        }
        let ids = lineup.map(\.id)
        if let current, !ids.contains(current) {
            // The wallpaper on screen left the playlist or the library.
            advance(after: current, in: oldLineup)
        } else if current == nil, ids != oldLineup {
            start()
        }
        if rotates != wasRotating || playlist?.intervalSeconds != oldInterval { scheduleRotation() }
    }

    /// Moves on to the playlist's next wallpaper.
    func next() {
        guard rotates, let current else { return }
        advance(after: current, in: lineup.map(\.id))
    }

    func setPaused(_ paused: Bool) {
        guard paused != self.paused else { return }
        self.paused = paused
        transition?.finish()
        active?.setPaused(paused)
        outgoing?.setPaused(paused)
        scheduleRotation()
    }

    func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        active?.setScreenLocked(locked)
        outgoing?.setScreenLocked(locked)
    }

    func revealSystemWallpaper() {
        active?.revealSystemWallpaper()
        outgoing?.revealSystemWallpaper()
    }

    /// Takes everything off the display.
    func stop() {
        clear()
    }

    // MARK: Showing

    /// Shows the display's content from its start: its wallpaper, or its playlist's first wallpaper that can play.
    /// Asking for content again gives the wallpapers that failed before another try.
    private func start() {
        error = nil
        let items = lineup
        failedIDs.subtract(items.map(\.id))
        switch content {
        case .wallpaper:
            guard let item = items.first else { return clear() }
            if playable(item) {
                show(item)
            } else {
                clear()
                error = String(localized: "Couldn’t find “\(item.name)”. It may have been moved or deleted.")
            }
        case .playlist:
            play(from: 0)
        case nil:
            clear()
        }
        scheduleRotation()
    }

    /// Shows the first playable playlist wallpaper after `id` (wrapping). `before` is the order `id` was shown in:
    /// when it has left the playlist since, its place there tells where to go on.
    private func advance(after id: UUID, in before: [UUID]) {
        play(from: Self.index(after: id, in: before, within: lineup.map(\.id)))
    }

    /// Shows the first playable wallpaper of the lineup from `start` on (wrapping), or nothing.
    private func play(from start: Int) {
        let items = lineup
        guard !items.isEmpty else {
            clear()
            error = Self.emptyPlaylist
            return
        }
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

    /// Starts `item` in a service of its own. A playlist's wallpaper comes in with the playlist's transition once it
    /// is ready; anything else replaces what is on screen then at once.
    private func show(_ item: VideoItem) {
        guard item.id != current else { return }  // the item that is already showing is left alone
        current = item.id
        showDepth += 1
        defer { showDepth -= 1 }
        // A transition still running ends here: its wallpaper is the one on screen now.
        transition?.finish()
        if ready {
            outgoing?.stop()
            outgoing = active
        } else {
            active?.stop()  // never shown; whatever was on screen before stays until the new one is ready
        }
        ready = false
        entrance = playlist?.transition ?? .cut
        entranceDuration = playlist?.transitionSeconds ?? 0
        let service: WallpaperService = item.isScene ? SceneRenderService(displayID: displayID)
                                                     : VideoRenderService(displayID: displayID)
        service.onReady = { [weak self, weak service] _ in
            guard let self, let service, service === self.active else { return }
            self.cameIn()
        }
        service.onFailure = { [weak self] item, message in self?.failed(item, message) }
        service.update(state)
        service.setPaused(paused)
        if screenLocked { service.setScreenLocked(true) }
        active = service
        service.start(item)
    }

    /// `active` has drawn its first frame: it comes in, and what it replaces goes once it is in.
    private func cameIn() {
        guard !ready, let active else { return }
        ready = true
        guard let outgoing, let from = outgoing.surface, let to = active.surface, entrance != .cut, !paused else {
            active.surface?.present()
            retireOutgoing()
            return
        }
        let transition = WallpaperTransition(entrance, duration: entranceDuration, from: from, to: to) { [weak self] in
            self?.transition = nil
            self?.retireOutgoing()
        }
        self.transition = transition
        transition.run()
    }

    private func retireOutgoing() {
        outgoing?.stop()
        outgoing = nil
    }

    private func clear() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        current = nil
        transition?.finish()
        retireOutgoing()
        active?.stop()
        active = nil
        ready = false
    }

    // From a render service: only the item currently on the display counts.
    private func failed(_ item: VideoItem, _ message: String?) {
        guard item.id == current else { return }
        failedIDs.insert(item.id)
        if rotates {
            advance(after: item.id, in: lineup.map(\.id))
        } else {
            clear()
        }
        error = message ?? String(localized: "Couldn’t show “\(item.name)”.")
        if showDepth == 0 { onChange?() }  // inside show() the caller reports the change itself
    }

    private func scheduleRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard !paused, current != nil, rotates, let interval = playlist?.intervalSeconds else { return }
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
