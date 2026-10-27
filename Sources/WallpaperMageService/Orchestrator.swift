import AppKit
import Core

// Decides what every display shows. Each connected display that has content (a wallpaper or a playlist) gets a
// DisplayPlayer, which draws it on that display alone; WallpaperStills keeps such a display's system wallpaper a still
// of what it shows, which is also what its menu bar and the lock screen show. A display whose content is taken away
// gets macOS's default wallpaper back. The service is the only writer of state.json (StateStore.commit / setMuted).
// The library's previews (LibraryPreviews) are made here too, as Settings asks for them.

@MainActor final class Orchestrator {
    private static let unreadableLibrary = String(localized: "Couldn’t read your library. Using the previous list.")

    /// Fired after any change of what the displays show or of the properties below (status item and socket status
    /// listen).
    var onChange: (@MainActor () -> Void)?

    /// Library + settings as last read from state.json.
    private(set) var state = LibraryState()
    private(set) var isPaused = false
    /// User-facing problem of the service as a whole (orange line in the menu, `message` in ServiceStatus).
    private(set) var message: String?

    private var players: [String: DisplayPlayer] = [:]
    private let stills = WallpaperStills()
    private let previews = LibraryPreviews()
    private var activity: NSObjectProtocol?
    private var screenLock: ScreenLockObserver?
    private var screenLocked = false
    private var screenObserver: NSObjectProtocol?

    init() {
        // While a scene loads, the previous video's window is still up, so both of the display's services let the
        // new still through. Settings shows the stills, so it hears of them.
        stills.onApplied = { [weak self] displays in
            displays.forEach { self?.players[$0]?.revealSystemWallpaper() }
            self?.onChange?()
        }
        previews.onChange = { [weak self] in self?.onChange?() }
    }

    var isLive: Bool { players.values.contains { $0.current != nil } }
    /// Every wallpaper is silent (the menu's Mute Sound).
    var muted: Bool { state.muted }

    // MARK: Lifecycle

    /// Once at launch: loads state.json, clears what older versions left for their lock screen and shows every
    /// display's wallpaper.
    func bootstrap() {
        let loaded = StateStore.load()
        state = loaded ?? LibraryState()
        stills.delay = state.stillDelay
        // An unreadable library must not cost the previews of the wallpapers it has.
        if loaded != nil { previews.retain(Set(state.videos.map(\.id))) }
        LegacyLockScreen.cleanUp(library: state.videos)
        screenLock = ScreenLockObserver { [weak self] locked in
            guard let self else { return }
            self.screenLocked = locked
            self.players.values.forEach { $0.setScreenLocked(locked) }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconcile()
                self?.onChange?()
            }
        }
        reconcile()
    }

    /// The UI's edited library: written to state.json with the service's own `muted` values, then applied.
    /// Returns false when state.json could not be written (nothing is applied then).
    func commit(_ edited: LibraryState) -> Bool {
        var fresh = edited
        guard StateStore.commit(&fresh) else { return false }
        reload()
        return true
    }

    /// Re-reads state.json and applies it when its revision differs from the applied one.
    func reload() {
        guard let fresh = StateStore.load() else {
            message = Self.unreadableLibrary
            onChange?()
            return
        }
        if message == Self.unreadableLibrary { message = nil }
        if fresh.revision != state.revision { apply(fresh) }
        onChange?()
    }

    /// Pauses/resumes every display AND its rotation.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        players.values.forEach { $0.setPaused(paused) }
        onChange?()
    }

    /// Mutes or unmutes every wallpaper. Written to state.json and applied at once.
    func setMuted(_ muted: Bool) {
        guard StateStore.setMuted(muted) != nil else { return }
        reload()
    }

    /// Makes the library's previews Settings asks for (LibraryPreviews).
    func makePreviews(_ requests: [PreviewRequest]) {
        previews.make(requests)
    }

    /// Takes the live wallpapers off the displays; their stills stay the system wallpapers. Idempotent.
    func shutdown() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        players.values.forEach { $0.stop() }
        players = [:]
        stills.stop()
        previews.stop()
        screenLock = nil
        updateActivity()
    }

    func status() -> ServiceStatus {
        let displays = NSScreen.screens.map { screen -> DisplayStatus in
            let id = screen.displayID
            let wallpaper = stills.systemWallpapers[id]
            let picture = wallpaper?.url ?? NSWorkspace.shared.desktopImageURL(for: screen)
            return DisplayStatus(id: id, itemID: players[id]?.current, error: players[id]?.error,
                                 systemWallpaper: picture?.path, stillItemID: wallpaper?.stillOf)
        }
        return ServiceStatus(paused: isPaused, muted: state.muted, displays: displays, stateRevision: state.revision,
                             message: message, previews: previews.status)
    }

    // MARK: Applying

    private func apply(_ fresh: LibraryState) {
        let old = state
        state = fresh
        stills.delay = fresh.stillDelay
        let library = Set(fresh.videos.map(\.id))
        if library != Set(old.videos.map(\.id)) { previews.retain(library) }
        // Content taken away (or deleted) gives the display macOS's default wallpaper back. It is set while the live
        // window still covers it; reconcile() then closes the window.
        let connected = Set(NSScreen.screens.map(\.displayID))
        for (id, config) in old.displays
        where config.content != nil && fresh.config(for: id).content == nil && connected.contains(id) {
            stills.revert(id)
        }
        reconcile()
    }

    /// A player for every connected display that has content, none for the rest.
    private func reconcile() {
        let connected = NSScreen.screens.map(\.displayID)
        for (id, player) in players where !connected.contains(id) || state.config(for: id).content == nil {
            player.stop()
            players[id] = nil
            stills.forget(id)
        }
        for id in connected where state.config(for: id).content != nil {
            if let player = players[id] {
                player.update(state)
            } else {
                let player = DisplayPlayer(displayID: id, state: state, paused: isPaused)
                player.onChange = { [weak self] in self?.changed() }
                if screenLocked { player.setScreenLocked(true) }
                players[id] = player
            }
        }
        syncStills()
        updateActivity()
    }

    /// A player moved on by itself (a playlist's next wallpaper, a failure): the stills follow and the status item
    /// and UI hear of it.
    private func changed() {
        syncStills()
        updateActivity()
        onChange?()
    }

    /// Each display's still follows what it shows; a display that shows nothing keeps its last still.
    private func syncStills() {
        for (id, player) in players {
            if let item = player.currentItem {
                stills.show(item, options: state.options(for: item.id, on: id), on: id)
            } else {
                stills.forget(id)
            }
        }
    }

    /// Keeps App Nap away while something is live.
    private func updateActivity() {
        if isLive, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Showing live wallpapers")
        } else if !isLive, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}
