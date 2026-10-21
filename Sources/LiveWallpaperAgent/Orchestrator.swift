import AppKit
import IOKit.ps
import Core

// Applies the library (state.json, written by the Settings app) to the desktop windows, the scene host and the lock
// screen, rotates on timers, handles failures and holds the App Nap activity. Two channels, one per
// WallpaperTarget (SPEC3.md section 1.2): a changed config of one target never restarts the other. No UI, no
// SwiftUI/Combine, never any network (SPEC2.md sections 3.3 and 7); scene files are never read here, the host does.

@MainActor final class Orchestrator {
    private static let unreadableLibrary = "Couldn’t read your library. Using the previous list."
    private static let nothingPlayable = "None of your wallpapers can be played."
    private static let crashLoop = "This scene keeps crashing the scene player and was skipped."
    private static let hostMissing = "The scene player is missing. Reinstall Live Wallpaper."
    private static let crashLimit = 3
    private static let crashWindow: TimeInterval = 120
    private static let hostIdleDelay: UInt64 = 10_000_000_000
    private static let resultLifetime: UInt64 = 3_000_000_000
    private static let screenDebounce: UInt64 = 3_000_000_000

    private struct PixelSize: Equatable {
        var width: Int
        var height: Int
    }

    /// The offline render of the lock channel's scene, with the command to repeat after a host crash.
    private struct LockJob {
        var id: String
        var itemID: UUID
        var size: PixelSize
        var command: HostCommand
    }

    /// Fired after any change of the observable properties below (status item and IPC status listen).
    var onChange: (@MainActor () -> Void)?

    /// Library + settings as last read from state.json (by bootstrap() and reload(revision:)).
    private(set) var state = LibraryState()
    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var failedIDs: Set<UUID> = []
    /// User-facing problem (orange line in the menu, `message` in AgentStatus). nil = fine.
    private(set) var statusMessage: String?
    /// The lock render (queued / rendering, and for 3 s after it finished or failed); nil otherwise.
    private(set) var lockRender: LockRenderStatus?
    /// Set by AgentMain while an older (phase-1) copy of the app is running; start() refuses and reports it.
    var blockedReason: String? { didSet { if blockedReason != oldValue { onChange?() } } }
    /// Fires when the scene host has ended after Orchestrator.shutdown (AgentMain waits for it before quitting).
    var onHostExited: (@MainActor () -> Void)? {
        get { host.onExited }
        set { host.onExited = newValue }
    }

    /// True while a lock video is being converted/installed or rendered.
    var lockBusy: Bool { lockApplies > 0 || lockRender?.state == .queued || lockRender?.state == .rendering }
    var muted: Bool { state.muted }
    var sceneHostRunning: Bool { host.isRunning }
    var hostIsExiting: Bool { host.isExiting }
    var canStart: Bool { hasPlayableTarget && blockedReason == nil }
    /// What the menu and the status report: a blocked start outranks a playback problem.
    var message: String? { blockedReason ?? statusMessage }

    func currentID(for target: WallpaperTarget) -> UUID? { current[target] }
    func currentItem(for target: WallpaperTarget) -> VideoItem? { state.videos.first { $0.id == current[target] } }
    func canRotate(_ target: WallpaperTarget) -> Bool { isRunning && current[target] != nil && state.hasMultipleItems(target) }

    private var hasPlayableTarget: Bool { WallpaperTarget.allCases.contains { state.canPlay($0) } }

    private let windows: WallpaperWindowManager
    private let lock: LockScreenWallpaper
    private let host: SceneHostClient
    private var current: [WallpaperTarget: UUID] = [:]
    private var rotationTimers: [WallpaperTarget: Timer] = [:]
    private var activity: NSObjectProtocol?
    private var lockApplies = 0
    private var statusSequence = 0

    // Desktop scene: handed over = the agent's windows are closed because the host shows the scene.
    private var desktopSceneID: UUID?
    private var sceneShown = false
    private var handedOver = false
    private var lastVideoURL: URL?  // what to show again if the host dies while it owns the screen
    private var sentFPSCap = 60
    private var powerTimer: Timer?

    private var lockJob: LockJob?
    private var lockSize: PixelSize?
    private var crashDates: [Date] = []

    private var restartTask: Task<Void, Never>?
    private var quitTask: Task<Void, Never>?
    private var resultTask: Task<Void, Never>?
    private var screenTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    #if DEBUG
    private var lastResidentLog = Date.distantPast
    #endif

    // Builds the backends only; no windows, no timers, no file access.
    init() {
        windows = WallpaperWindowManager()
        lock = LockScreenWallpaper()
        host = SceneHostClient()
    }

    // MARK: Lifecycle (called by AgentMain)

    /// Once, after IPC is listening: loads state.json and agent.json; resumes when `wantsRunning`
    /// (and canStart), otherwise `lock.restore()` so a crashed run cannot leave Apple's Aerials swapped.
    func bootstrap() {
        windows.onPlaybackFailure = { [weak self] url in self?.playbackFailed(url) }
        host.onStatus = { [weak self] status in self?.hostStatus(status) }
        host.onTerminated = { [weak self] unexpectedly in self?.hostTerminated(unexpectedly: unexpectedly) }
        state = StateStore.load() ?? LibraryState()
        windows.setMuted(state.muted)
        let wantsRunning = AgentRecordStore.load().wantsRunning
        // An older copy owns the wallpapers while it runs: restoring them from under it would break it.
        guard blockedReason == nil else { return }
        if wantsRunning, hasPlayableTarget {
            start(at: nil)
        } else {
            setWantsRunning(false)
            lock.restore()
        }
    }

    /// state.json changed. `revision` is only a hint: the file decides. It is applied whenever its revision differs
    /// from the applied one (a lower revision means the file was replaced and still wins).
    func reload(revision: Int?) {
        guard let fresh = StateStore.load() else {
            statusMessage = Self.unreadableLibrary
            onChange?()
            return
        }
        if statusMessage == Self.unreadableLibrary { statusMessage = nil }
        if fresh.revision != state.revision { apply(fresh) }
        changed()
    }

    /// Begins at `id` (on `target` only, or on both channels when nil), else each target's selected item, else its
    /// first. No-op when already running or nothing can be played. Persists `wantsRunning = true`.
    func start(at id: UUID?, target: WallpaperTarget? = nil) {
        guard !isRunning, canStart else { return }
        statusMessage = nil
        failedIDs = []
        isRunning = true
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Playing live wallpaper")
        setWantsRunning(true)
        observeSystem()
        for channel in WallpaperTarget.allCases where state.canPlay(channel) {
            let items = state.items(for: channel)
            let wanted = target == nil || target == channel ? id : nil
            applyItem(on: channel, startingAt: items.firstIndex { $0.id == wanted } ?? selectedIndex(of: channel))
        }
        changed()
    }

    /// Hides the windows, restores originals, persists `wantsRunning = false`. The agent stays alive.
    func stop() {
        guard isRunning else { return }
        halt()
        changed()
    }

    /// Jumps to `id` on `target` (nil = both), starting playback if needed.
    func play(_ id: UUID, target: WallpaperTarget? = nil) {
        guard state.videos.contains(where: { $0.id == id }) else { return }
        guard isRunning else {
            start(at: id, target: target)
            return
        }
        failedIDs.remove(id)  // asking for it by name is worth another try
        for channel in channels(target) where state.canPlay(channel) {
            if let index = state.items(for: channel).firstIndex(where: { $0.id == id }) {
                applyItem(on: channel, startingAt: index)
            }
        }
        changed()
    }

    /// Moves `target` (nil = both) on; a channel with fewer than two items stays where it is.
    func next(target: WallpaperTarget? = nil) {
        guard isRunning else { return }
        for channel in channels(target) where current[channel] != nil && state.hasMultipleItems(channel) {
            let items = state.items(for: channel)
            applyItem(on: channel, startingAt: (items.firstIndex { $0.id == current[channel] } ?? -1) + 1)
        }
        changed()
    }

    /// Pauses/resumes the video, the scene AND the rotation timers. A lock render goes on.
    func setPaused(_ paused: Bool) {
        guard isRunning, paused != isPaused else { return }
        isPaused = paused
        windows.setPaused(paused)
        if desktopSceneID != nil { host.send(HostCommand(kind: .setPaused, paused: paused)) }
        WallpaperTarget.allCases.forEach(scheduleRotation)
        changed()
    }

    /// The menu's Mute Sound: written to state.json (the one write the agent makes) and applied at once.
    func setMuted(_ muted: Bool) {
        guard StateStore.setMuted(muted) != nil else { return }
        reload(revision: nil)
    }

    /// Tears everything down and restores originals, and tells the scene host to quit. Idempotent (called from quit
    /// and from applicationShouldTerminate). `userQuit` true also persists `wantsRunning = false`;
    /// false (logout, SIGTERM, crash recovery path) leaves it so the next launch resumes.
    func shutdown(userQuit: Bool) {
        if userQuit { setWantsRunning(false) }
        if isRunning { teardown() }
        quitTask?.cancel()
        quitTask = nil
        host.shutdown()
    }

    /// Snapshot for IPC; bumps the per-run sequence number.
    func status(reply: String?) -> AgentStatus {
        statusSequence += 1
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return AgentStatus(seq: statusSequence, reply: reply, pid: ProcessInfo.processInfo.processIdentifier,
                           agentVersion: version, isRunning: isRunning, isPaused: isPaused,
                           currentID: current[.desktop], failedIDs: Array(failedIDs),
                           message: message, lockBusy: lockBusy,
                           stateRevision: state.revision, quitting: false,
                           lockID: current[.lock], muted: state.muted, sceneHostRunning: host.isRunning,
                           lockRender: lockRender)
    }

    // MARK: Library changes

    // Runs once for a whole new state: each channel compares its own config, so one target's change never
    // touches the other. Adding videos never changes what is playing.
    private func apply(_ fresh: LibraryState) {
        let old = state
        state = fresh  // first, so canPlay and friends read the new values
        failedIDs.formIntersection(fresh.videos.map(\.id))
        if old.muted != fresh.muted {
            windows.setMuted(fresh.muted)
            if desktopSceneID != nil { host.send(HostCommand(kind: .setMuted, muted: fresh.muted)) }
        }
        guard isRunning else { return }
        guard hasPlayableTarget else {
            halt()
            return
        }
        WallpaperTarget.allCases.forEach { reconcile($0, from: old) }
    }

    private func reconcile(_ channel: WallpaperTarget, from old: LibraryState) {
        guard state.canPlay(channel) else {
            deactivate(channel)
            return
        }
        guard let playing = current[channel] else {
            if !old.canPlay(channel) { applyItem(on: channel, startingAt: selectedIndex(of: channel)) }
            return
        }
        let items = state.items(for: channel)
        let selected = state.config(for: channel).selectedID
        if !items.contains(where: { $0.id == playing }) {
            // The current item was removed: continue with whatever now sits at its index.
            let oldIndex = old.items(for: channel).firstIndex { $0.id == playing } ?? 0
            applyItem(on: channel, startingAt: min(oldIndex, items.count))
        } else if selected != old.config(for: channel).selectedID, let selected,
                  let index = items.firstIndex(where: { $0.id == selected }) {
            failedIDs.remove(selected)
            applyItem(on: channel, startingAt: index)
        }
        if old.rotates(channel) != state.rotates(channel) || old.interval(for: channel) != state.interval(for: channel) {
            scheduleRotation(channel)
        }
    }

    private func playbackFailed(_ url: URL) {
        guard isRunning, let item = state.videos.first(where: { $0.path == url.path }) else { return }
        failedIDs.insert(item.id)
        if item.id == current[.desktop] { advance(.desktop, after: item.id) }
        changed()
    }

    // The status item reads `onChange`, so every public entry point ends here. A run whose channels all ran out of
    // playable items stops, keeping the message that says why.
    private func changed() {
        if isRunning, current.isEmpty {
            let reason = statusMessage ?? Self.nothingPlayable
            halt()
            statusMessage = reason
        }
        onChange?()
    }

    // MARK: Applying

    private func channels(_ target: WallpaperTarget?) -> [WallpaperTarget] {
        target.map { [$0] } ?? WallpaperTarget.allCases
    }

    private func selectedIndex(of channel: WallpaperTarget) -> Int {
        let selected = state.config(for: channel).selectedID
        return state.items(for: channel).firstIndex { $0.id == selected } ?? 0
    }

    // Applies the first playable item at or after `start` (wrapping), then restarts that channel's rotation timer.
    private func applyItem(on channel: WallpaperTarget, startingAt start: Int) {
        let items = state.items(for: channel)
        guard let index = firstPlayableIndex(in: items, from: start) else {
            deactivate(channel)
            statusMessage = Self.nothingPlayable
            return
        }
        statusMessage = nil
        let item = items[index]
        // The lock screen conversion is expensive, so the item that is already showing is left alone.
        if item.id != current[channel] {
            current[channel] = item.id
            show(item, on: channel)
        }
        scheduleRotation(channel)
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

    // Marks `id` failed on `channel` (the caller sets the message) and moves that channel to the next item.
    private func advance(_ channel: WallpaperTarget, after id: UUID) {
        let items = state.items(for: channel)
        applyItem(on: channel, startingAt: (items.firstIndex { $0.id == id } ?? -1) + 1)
    }

    private func fail(_ item: VideoItem, on channel: WallpaperTarget, _ message: String) {
        failedIDs.insert(item.id)
        advance(channel, after: item.id)
        statusMessage = message
    }

    private func show(_ item: VideoItem, on channel: WallpaperTarget) {
        switch (channel, item.isScene) {
        case (.desktop, false): showVideo(item.url)
        case (.desktop, true): showScene(item)
        case (.lock, false):
            cancelLockJob()
            applyLock(item.url)
        case (.lock, true): renderLock(item)
        }
    }

    // Stops one channel and gives its target back to Apple.
    private func deactivate(_ channel: WallpaperTarget) {
        rotationTimers[channel]?.invalidate()
        rotationTimers[channel] = nil
        guard current[channel] != nil else { return }
        current[channel] = nil
        switch channel {
        case .desktop:
            windows.hide()
            handedOver = false
            dropDesktopScene()
        case .lock:
            cancelLockJob()
            lock.restore()
        }
    }

    // MARK: Desktop

    private func showWindows(_ url: URL) {
        lastVideoURL = url
        handedOver = false
        windows.show(url: url)
        windows.setPaused(isPaused)
    }

    // Windows first: they sit in front of the host's because they are created later at the same level.
    private func showVideo(_ url: URL) {
        showWindows(url)
        dropDesktopScene()
    }

    private func dropDesktopScene() {
        guard desktopSceneID != nil else { return }
        desktopSceneID = nil
        host.send(HostCommand(kind: .hideScene))
        syncHost()
    }

    // The agent's windows stay up (previous wallpaper) until the host reports its first frame.
    private func showScene(_ item: VideoItem) {
        guard SceneHostClient.isInstalled else {
            fail(item, on: .desktop, Self.hostMissing)
            return
        }
        desktopSceneID = item.id
        sceneShown = false
        host.send(sceneCommand(for: item))
        if isPaused { host.send(HostCommand(kind: .setPaused, paused: true)) }
        syncHost()
    }

    private func sceneCommand(for item: VideoItem) -> HostCommand {
        sentFPSCap = PowerSupply.isBattery ? 30 : 60
        return HostCommand(kind: .showScene, itemID: item.id, scenePath: item.path, previewPath: item.previewPath,
                           assetsPath: sharedAssetsPath, muted: state.muted, fpsCap: sentFPSCap)
    }

    private var sharedAssetsPath: String? {
        let assets = AppPaths.sharedAssetsDirectory.path
        return FileManager.default.fileExists(atPath: assets) ? assets : nil
    }

    private func sceneStatus(_ status: HostStatus, id: UUID) {
        switch status.sceneState {
        case .playing, .paused, .fallbackStill:
            sceneShown = true
            guard !handedOver else { return }
            handedOver = true
            windows.hide()
            statusMessage = nil
        case .failed:
            guard current[.desktop] == id, let item = state.videos.first(where: { $0.id == id }) else { return }
            fail(item, on: .desktop, "Couldn’t play “\(item.name)”." + (status.sceneMessage.map { " \($0)" } ?? ""))
        case .none, .loading:
            break
        }
    }

    // MARK: Lock screen

    private func applyLock(_ url: URL) {
        // Overlapping applies are coalesced by the lock screen backend, so the flag tracks how many are in flight.
        lockApplies += 1
        Task { @MainActor [weak self] in
            guard let self else { return }
            var failure: String?
            do { try await self.lock.apply(from: url) } catch { failure = error.localizedDescription }
            self.lockApplies -= 1
            if let failure, self.isRunning { self.statusMessage = failure }
            self.onChange?()
        }
    }

    private func lockPixelSize() -> PixelSize {
        let size = LockScreenWallpaper.largestScreenPixelSize() ?? CGSize(width: 1920, height: 1080)
        return PixelSize(width: Int(size.width.rounded()) & ~1, height: Int(size.height.rounded()) & ~1)
    }

    // A scene on the lock screen is a video the host renders once per resolution (SPEC3.md section 1.5); the previous
    // lock wallpaper stays until it is installed.
    private func renderLock(_ item: VideoItem) {
        let size = lockPixelSize()
        lockSize = size
        let video = LockRenderCache.videoURL(for: item, width: size.width, height: size.height)
        if LockRenderCache.isValid(for: item, width: size.width, height: size.height) {
            cancelLockJob()
            applyLock(video)
            return
        }
        if let job = lockJob, job.itemID == item.id, job.size == size { return }  // already on it
        cancelLockJob()
        guard SceneHostClient.isInstalled else {
            fail(item, on: .lock, Self.hostMissing)
            return
        }
        let id = UUID().uuidString
        let command = HostCommand(kind: .renderLock, itemID: item.id, scenePath: item.path, previewPath: item.previewPath,
                                  assetsPath: sharedAssetsPath, jobID: id, width: size.width, height: size.height,
                                  fps: 30, loopSeconds: item.scene?.loopSeconds, outputPath: video.path)
        lockJob = LockJob(id: id, itemID: item.id, size: size, command: command)
        lockRender = LockRenderStatus(itemID: item.id, state: .queued)
        host.send(command)
        syncHost()
    }

    private func cancelLockJob() {
        resultTask?.cancel()
        resultTask = nil
        lockRender = nil
        guard let job = lockJob else { return }
        lockJob = nil
        host.send(HostCommand(kind: .cancelRender, jobID: job.id))
        syncHost()
    }

    private func jobStatus(_ status: HostStatus, job: LockJob) {
        switch status.jobState {
        case .rendering:
            lockRender = LockRenderStatus(itemID: job.itemID, state: .rendering, progress: status.jobProgress)
        case .finished:
            lockJob = nil
            syncHost()
            lockRenderFinished(job)
        case .failed, .cancelled:
            lockJob = nil
            syncHost()
            lockRenderFailed(job)
        case .idle:
            break
        }
    }

    private func lockRenderFinished(_ job: LockJob) {
        guard current[.lock] == job.itemID, let item = state.videos.first(where: { $0.id == job.itemID }) else {
            lockRender = nil
            return
        }
        // The host only writes the .mov; the cache record that makes it valid is ours.
        try? LockRenderCache.writeMeta(LockRenderCache.Meta(
            width: job.size.width, height: job.size.height, fps: 1, loopSeconds: 4,
            sourceStamp: LockRenderCache.sourceStamp(for: item)), for: item)
        guard LockRenderCache.isValid(for: item, width: job.size.width, height: job.size.height) else {
            lockRenderFailed(job)
            return
        }
        showResult(LockRenderStatus(itemID: item.id, state: .finished, progress: 1))
        applyLock(LockRenderCache.videoURL(for: item, width: job.size.width, height: job.size.height))
    }

    private func lockRenderFailed(_ job: LockJob) {
        guard current[.lock] == job.itemID, let item = state.videos.first(where: { $0.id == job.itemID }) else {
            lockRender = nil
            return
        }
        let text = "Couldn’t render “\(item.name)” for the lock screen."
        fail(item, on: .lock, text)
        // Unless the channel moved on to a render of its own, the failure stays visible for a moment.
        if lockRender == nil { showResult(LockRenderStatus(itemID: item.id, state: .failed, message: text)) }
    }

    private func showResult(_ result: LockRenderStatus) {
        lockRender = result
        resultTask?.cancel()
        resultTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.resultLifetime)
            guard !Task.isCancelled, let self, self.lockRender == result else { return }
            self.resultTask = nil
            self.lockRender = nil
            self.onChange?()
        }
    }

    // MARK: Scene host

    private func hostStatus(_ status: HostStatus) {
        #if DEBUG
        if Date().timeIntervalSince(lastResidentLog) >= 5 {
            lastResidentLog = Date()
            NSLog("scene host: %d MB", status.residentMB)
        }
        #endif
        if let id = desktopSceneID, status.sceneItemID == id { sceneStatus(status, id: id) }
        // A status about an earlier job (cancelled, replaced) says nothing about the current one.
        if let job = lockJob, status.jobID == job.id { jobStatus(status, job: job) }
        changed()
    }

    private func hostTerminated(unexpectedly: Bool) {
        // The host's windows went with it: show our last video again until it is back.
        if handedOver, let url = lastVideoURL { showWindows(url) }
        defer { changed() }
        guard isRunning, desktopSceneID != nil || lockJob != nil else {
            syncHost()
            return
        }
        if unexpectedly {
            let now = Date()
            crashDates = crashDates.filter { now.timeIntervalSince($0) < Self.crashWindow } + [now]
            if crashDates.count >= Self.crashLimit { skipCrashingItem() }
        }
        scheduleRestart()
    }

    // The item that was loading or rendering when the host died for the third time is the suspect.
    private func skipCrashingItem() {
        crashDates = []
        if let id = desktopSceneID, !sceneShown, let item = state.videos.first(where: { $0.id == id }) {
            fail(item, on: .desktop, Self.crashLoop)
        } else if let job = lockJob, let item = state.videos.first(where: { $0.id == job.itemID }) {
            lockJob = nil
            fail(item, on: .lock, Self.crashLoop)
            syncHost()
        } else if let id = desktopSceneID, let item = state.videos.first(where: { $0.id == id }) {
            fail(item, on: .desktop, Self.crashLoop)
        }
    }

    // Back-off 1 s, 2 s, 4 s, then everything the host should be doing is sent again.
    private func scheduleRestart() {
        let seconds = UInt64(1 << min(max(crashDates.count - 1, 0), 2))
        restartTask?.cancel()
        restartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil
            self.resumeHostWork()
        }
    }

    // A host that was started meanwhile (a channel change) may already have some of this: showScene for the same
    // item only updates it, and a render the host reports is not repeated.
    private func resumeHostWork() {
        guard isRunning else { return }
        if let id = desktopSceneID, let item = state.videos.first(where: { $0.id == id }) {
            host.send(sceneCommand(for: item))
            if isPaused { host.send(HostCommand(kind: .setPaused, paused: true)) }
        }
        if var job = lockJob, host.lastStatus?.jobID != job.id {
            job.command.id = UUID().uuidString  // the same job, a new command
            host.send(job.command)
        }
    }

    // The host runs while a scene is on the desktop or a render is going; 10 s after neither it is told to quit.
    private func syncHost() {
        if desktopSceneID != nil || lockJob != nil {
            quitTask?.cancel()
            quitTask = nil
        } else if host.isRunning, quitTask == nil {
            quitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: Self.hostIdleDelay)
                guard !Task.isCancelled, let self else { return }
                self.quitTask = nil
                if self.desktopSceneID == nil, self.lockJob == nil { self.host.shutdown() }
            }
        }
        if desktopSceneID != nil, powerTimer == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.powerSourceMayHaveChanged() }
            }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            powerTimer = timer
        } else if desktopSceneID == nil {
            powerTimer?.invalidate()
            powerTimer = nil
        }
    }

    // 30 fps on battery, 60 on power: the same showScene again only updates the host's cap.
    private func powerSourceMayHaveChanged() {
        guard let id = desktopSceneID, let item = state.videos.first(where: { $0.id == id }),
              (PowerSupply.isBattery ? 30 : 60) != sentFPSCap else { return }
        host.send(sceneCommand(for: item))
    }

    // MARK: System events

    private func observeSystem() {
        windows.setScreenLocked(false)
        lock.onScreenLock = { [weak self] locked in self?.windows.setScreenLocked(locked) }
        lock.startObservingLock()
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.screensChanged() }
        }
    }

    // Debounced: a display change fires several notifications. A new size needs a new lock video.
    private func screensChanged() {
        screenTask?.cancel()
        screenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.screenDebounce)
            guard !Task.isCancelled, let self else { return }
            self.screenTask = nil
            if self.isRunning, let id = self.current[.lock], let item = self.state.videos.first(where: { $0.id == id }),
               item.isScene, self.lockPixelSize() != self.lockSize {
                self.renderLock(item)
                self.changed()
            }
        }
    }

    private func scheduleRotation(_ channel: WallpaperTarget) {
        rotationTimers[channel]?.invalidate()
        rotationTimers[channel] = nil
        guard isRunning, !isPaused, current[channel] != nil, state.rotates(channel) else { return }
        let interval = state.interval(for: channel)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.next(target: channel) }
        }
        timer.tolerance = min(interval * 0.1, 5)
        RunLoop.main.add(timer, forMode: .common)
        rotationTimers[channel] = timer
    }

    // MARK: Stopping

    private func teardown() {
        rotationTimers.values.forEach { $0.invalidate() }
        rotationTimers.removeAll()
        [restartTask, screenTask].forEach { $0?.cancel() }
        restartTask = nil
        screenTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        windows.hide()
        handedOver = false
        dropDesktopScene()
        cancelLockJob()
        lock.onScreenLock = nil
        lock.restore()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        isRunning = false
        isPaused = false
        current.removeAll()
        syncHost()
    }

    // An explicit or automatic stop: back to Apple's wallpapers, and nothing to resume at the next launch.
    private func halt() {
        teardown()
        statusMessage = nil
        setWantsRunning(false)
    }

    private func setWantsRunning(_ wants: Bool) {
        AgentRecordStore.update { $0.wantsRunning = wants }
    }
}

// Battery or mains: the live scene is capped at 30 fps on battery.
private enum PowerSupply {
    static var isBattery: Bool {
        let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        guard let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() else { return false }
        return (source as String) == kIOPSBatteryPowerValue
    }
}
