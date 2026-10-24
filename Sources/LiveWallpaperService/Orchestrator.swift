import AppKit
import Core

// Decides what the desktop shows: the selected wallpaper, rotation through the playlist and the next item when one
// cannot play. The desktop is drawn by a WallpaperService (VideoRenderService or SceneRenderService); WallpaperStills
// keeps every display's system wallpaper a still of it, which is also what the lock screen shows. The service is
// the only writer of state.json (StateStore.commit / setMuted).

@MainActor final class Orchestrator {
    private static let unreadableLibrary = "Couldn’t read your library. Using the previous list."
    private static let nothingPlayable = "None of your wallpapers can be played."

    /// Fired after any change of the observable properties below (status item and socket status listen).
    var onChange: (@MainActor () -> Void)?

    /// Library + settings as last read from state.json.
    private(set) var state = LibraryState()
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var failedIDs: Set<UUID> = []
    /// User-facing problem (orange line in the menu, `message` in ServiceStatus). nil = fine.
    private(set) var statusMessage: String?
    /// Why the last item could not play (ServiceStatus.error); cleared by start and play.
    private(set) var itemError: String?

    var muted: Bool { state.muted }
    var canStart: Bool { state.canPlay }
    var message: String? { statusMessage }
    var currentItem: VideoItem? { state.videos.first { $0.id == current } }
    var canRotate: Bool { isRunning && current != nil && state.hasMultipleItems }

    private let video = VideoRenderService()
    private let scene = SceneRenderService()
    private let stills = WallpaperStills()
    private var current: UUID?
    private var rotationTimer: Timer?
    private var activity: NSObjectProtocol?
    private var screenLock: ScreenLockObserver?
    private var showDepth = 0  // > 0 while show() runs: a render service may report a failure synchronously

    init() {
        // The scene is on screen: the previous (video) wallpaper can go.
        scene.onReady = { [weak self] _ in self?.video.stop() }
        // While a scene loads, the previous video's windows are still up, so both services let the new still through.
        stills.onApplied = { [weak self] in
            self?.video.revealSystemWallpaper()
            self?.scene.revealSystemWallpaper()
        }
    }

    // MARK: Lifecycle

    /// Once at launch: loads state.json and agent.json, clears what older versions left for their lock screen and
    /// resumes when `wantsRunning` (and canStart).
    func bootstrap() {
        for service in [video, scene] as [WallpaperService] {
            service.onFailure = { [weak self] item, message in self?.failed(item, message) }
        }
        state = StateStore.load() ?? LibraryState()
        stills.delay = state.stillDelay
        LegacyLockScreen.cleanUp(library: state.videos)
        video.setMuted(state.muted)
        scene.setMuted(state.muted)
        if AgentRecordStore.load().wantsRunning, canStart {
            start(at: nil)
        } else {
            setWantsRunning(false)
        }
    }

    /// The UI's edited library: written to state.json with the service's own `muted`, then applied.
    /// Returns false when state.json could not be written (nothing is applied then).
    func commit(_ edited: LibraryState) -> Bool {
        var fresh = edited
        fresh.muted = state.muted
        guard StateStore.commit(&fresh) else { return false }
        reload()
        return true
    }

    /// Re-reads state.json and applies it when its revision differs from the applied one.
    func reload() {
        guard let fresh = StateStore.load() else {
            statusMessage = Self.unreadableLibrary
            onChange?()
            return
        }
        if statusMessage == Self.unreadableLibrary { statusMessage = nil }
        if fresh.revision != state.revision { apply(fresh) }
        changed()
    }

    /// Begins at `id`, else the selected item, else the first. No-op when already running or nothing can be played.
    /// Persists `wantsRunning = true`.
    func start(at id: UUID?) {
        guard !isRunning, canStart else { return }
        statusMessage = nil
        failedIDs = []
        itemError = nil
        isRunning = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Playing live wallpaper")
        setWantsRunning(true)
        observeSystem()
        applyItem(startingAt: state.items.firstIndex { $0.id == id } ?? selectedIndex)
        changed()
    }

    /// Stops playback and persists `wantsRunning = false`. The service stays alive, and the stills stay the system
    /// wallpaper.
    func stop() {
        guard isRunning else { return }
        halt()
        changed()
    }

    /// Jumps to `id`, starting playback if needed.
    func play(_ id: UUID) {
        guard state.videos.contains(where: { $0.id == id }) else { return }
        guard isRunning else {
            start(at: id)
            return
        }
        failedIDs.remove(id)  // asking for it by name is worth another try
        if state.canPlay, let index = state.items.firstIndex(where: { $0.id == id }) {
            itemError = nil
            applyItem(startingAt: index)
        }
        changed()
    }

    /// Moves on to the next item; with fewer than two items the desktop stays where it is.
    func next() {
        guard isRunning else { return }
        if current != nil, state.hasMultipleItems {
            applyItem(startingAt: (state.items.firstIndex { $0.id == current } ?? -1) + 1)
        }
        changed()
    }

    /// Pauses/resumes the desktop AND the rotation timer.
    func setPaused(_ paused: Bool) {
        guard isRunning, paused != isPaused else { return }
        isPaused = paused
        video.setPaused(paused)
        scene.setPaused(paused)
        scheduleRotation()
        changed()
    }

    /// Written to state.json and applied at once.
    func setMuted(_ muted: Bool) {
        guard StateStore.setMuted(muted) != nil else { return }
        reload()
    }

    /// Tears everything down. Idempotent. `userQuit` true also persists `wantsRunning = false`; false (logout,
    /// SIGTERM) leaves it so the next launch resumes.
    func shutdown(userQuit: Bool) {
        if userQuit { setWantsRunning(false) }
        if isRunning { teardown() }
    }

    func status() -> ServiceStatus {
        ServiceStatus(
            playback: isRunning ? (isPaused ? .paused : .playing) : .stopped,
            itemID: current, error: itemError, stateRevision: state.revision, muted: state.muted, message: message)
    }

    // MARK: Library changes

    // Adding videos never changes what is playing.
    private func apply(_ fresh: LibraryState) {
        let old = state
        state = fresh  // first, so canPlay and friends read the new values
        failedIDs.formIntersection(fresh.videos.map(\.id))
        if old.muted != fresh.muted {
            video.setMuted(fresh.muted)
            scene.setMuted(fresh.muted)
        }
        scene.update(fresh)  // diffs itself; no restart
        stills.delay = fresh.stillDelay
        guard isRunning else { return }
        guard canStart else {
            halt()
            return
        }
        reconcile(from: old)
        // A scene framed differently needs new stills; anything else leaves them as they are.
        if let item = currentItem { stills.show(item, options: sceneOptions(of: item)) }
    }

    private func reconcile(from old: LibraryState) {
        guard let playing = current else {
            if !old.canPlay { applyItem(startingAt: selectedIndex) }
            return
        }
        let items = state.items
        let selected = state.desktop.selectedID
        if !items.contains(where: { $0.id == playing }) {
            // The current item was removed: continue with whatever now sits at its index.
            let oldIndex = old.items.firstIndex { $0.id == playing } ?? 0
            applyItem(startingAt: min(oldIndex, items.count))
        } else if selected != old.desktop.selectedID, let selected,
                  let index = items.firstIndex(where: { $0.id == selected }) {
            failedIDs.remove(selected)
            itemError = nil
            applyItem(startingAt: index)
        }
        if old.rotates != state.rotates || old.desktop.intervalSeconds != state.desktop.intervalSeconds {
            scheduleRotation()
        }
    }

    // From a render service: only the item currently on the desktop counts.
    private func failed(_ item: VideoItem, _ message: String?) {
        guard isRunning, item.id == current else { return }
        fail(item, message)
        if showDepth == 0 { changed() }  // inside show() the public entry point that called it ends with changed()
    }

    // The status item reads `onChange`, so every public entry point ends here. A run that ran out of playable items
    // stops, keeping the message that says why.
    private func changed() {
        if isRunning, current == nil {
            let reason = statusMessage ?? Self.nothingPlayable
            halt()
            statusMessage = reason
        }
        onChange?()
    }

    // MARK: Applying

    private var selectedIndex: Int {
        state.items.firstIndex { $0.id == state.desktop.selectedID } ?? 0
    }

    // Shows the first playable item at or after `start` (wrapping), then restarts the rotation timer.
    private func applyItem(startingAt start: Int) {
        let items = state.items
        guard let index = firstPlayableIndex(in: items, from: start) else {
            clear()
            statusMessage = Self.nothingPlayable
            return
        }
        statusMessage = nil
        let item = items[index]
        // The item that is already showing is left alone.
        if item.id != current {
            current = item.id
            show(item)
        }
        scheduleRotation()
    }

    private func firstPlayableIndex(in items: [VideoItem], from start: Int) -> Int? {
        for offset in 0..<items.count {
            let index = (start + offset) % items.count
            let item = items[index]
            if failedIDs.contains(item.id) { continue }
            if FileManager.default.fileExists(atPath: item.path) { return index }
            failedIDs.insert(item.id)
        }
        return nil
    }

    // Marks `item` failed, moves on to the next item and keeps the reason.
    private func fail(_ item: VideoItem, _ message: String?) {
        failedIDs.insert(item.id)
        itemError = message
        applyItem(startingAt: (state.items.firstIndex { $0.id == item.id } ?? -1) + 1)
        if let message { statusMessage = message }
    }

    private func show(_ item: VideoItem) {
        showDepth += 1
        defer { showDepth -= 1 }
        // Before the render service starts: if it fails at once, the item after it asks for its own stills last.
        stills.show(item, options: sceneOptions(of: item))
        if item.isScene {
            // The video windows stay up (previous wallpaper) until the scene renderer shows its first frame.
            scene.update(state)
            scene.start(item)
            if scene.item?.id == item.id { scene.setPaused(isPaused) }
        } else {
            scene.stop()
            video.start(item)
            video.setPaused(isPaused)
        }
    }

    private func sceneOptions(of item: VideoItem) -> SceneOptions? {
        item.isScene ? state.sceneOptions[item.id.uuidString] ?? .standard : nil
    }

    // Nothing left to show. The stills stay the system wallpaper.
    private func clear() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard current != nil else { return }
        current = nil
        video.stop()
        scene.stop()
        stills.stop()
    }

    // MARK: System events

    private func observeSystem() {
        video.setScreenLocked(false)
        scene.setScreenLocked(false)
        guard screenLock == nil else { return }
        screenLock = ScreenLockObserver { [weak self] locked in
            self?.video.setScreenLocked(locked)
            self?.scene.setScreenLocked(locked)
        }
    }

    private func scheduleRotation() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        guard isRunning, !isPaused, current != nil, state.rotates else { return }
        let interval = state.desktop.intervalSeconds
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next() }
        }
        timer.tolerance = min(interval * 0.1, 5)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimer = timer
    }

    // MARK: Stopping

    private func teardown() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        video.stop()
        scene.stop()
        stills.stop()
        screenLock = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRunning = false
        isPaused = false
        current = nil
    }

    // An explicit or automatic stop: nothing to resume at the next launch.
    private func halt() {
        teardown()
        statusMessage = nil
        setWantsRunning(false)
    }

    private func setWantsRunning(_ wants: Bool) {
        AgentRecordStore.update { $0.wantsRunning = wants }
    }
}
