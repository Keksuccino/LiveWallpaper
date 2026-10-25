import AppKit
import AVFoundation
import Core

/// The video on its display: the picture placed by the wallpaper's alignment and, behind it while the alignment
/// leaves bars, a blurred copy that covers the display. The copy is drawn at an eighth of the size and scaled up, so
/// its blur costs little; both layers show the same player, which decodes once.
private final class PlayerView: NSView {
    private static let backdropScale: CGFloat = 8
    private let picture = AVPlayerLayer()
    private let backdrop = AVPlayerLayer()
    /// The wallpaper's options and the video's pixel size; nil until both are known (the picture then covers).
    var look: (options: WallpaperOptions, videoSize: CGSize)? { didSet { needsLayout = true } }
    /// Called on the main actor whenever the picture has a frame of its player to show.
    var onReadyForDisplay: (() -> Void)?
    private var readiness: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        layer?.backgroundColor = NSColor.black.cgColor
        picture.videoGravity = .resizeAspectFill
        backdrop.videoGravity = .resizeAspectFill
        backdrop.contentsScale = 1
        backdrop.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 5]) as Any]
        backdrop.isHidden = true
        layer?.addSublayer(backdrop)
        layer?.addSublayer(picture)
        readiness = observeReadiness(of: picture) { [weak self] in
            Task { @MainActor [weak self] in self?.onReadyForDisplay?() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var player: AVPlayer? {
        didSet {
            picture.player = player
            backdrop.player = backdrop.isHidden ? nil : player
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let scale = window?.backingScaleFactor ?? 2
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard let look, let placement = VideoPlacement(look.options, content: look.videoSize, target: target) else {
            picture.videoGravity = .resizeAspectFill
            picture.setAffineTransform(.identity)
            picture.frame = bounds
            showBackdrop(false, flipped: false)
            return
        }
        // The placement counts from the top-left in pixels; the layer counts from the bottom-left in points.
        let frame = placement.frame
        picture.videoGravity = .resize
        picture.setAffineTransform(.identity)
        picture.bounds = CGRect(origin: .zero, size: CGSize(width: frame.width / scale, height: frame.height / scale))
        picture.position = CGPoint(x: frame.midX / scale, y: bounds.height - frame.midY / scale)
        picture.setAffineTransform(CGAffineTransform(scaleX: placement.flipped ? -1 : 1, y: 1))
        showBackdrop(placement.blurredBars, flipped: placement.flipped)
    }

    private func showBackdrop(_ show: Bool, flipped: Bool) {
        backdrop.isHidden = !show
        backdrop.player = show ? player : nil
        guard show else { return }
        let k = Self.backdropScale
        backdrop.setAffineTransform(.identity)
        backdrop.bounds = CGRect(x: 0, y: 0, width: bounds.width / k, height: bounds.height / k)
        backdrop.position = CGPoint(x: bounds.midX, y: bounds.midY)
        backdrop.setAffineTransform(CGAffineTransform(scaleX: flipped ? -k : k, y: k))
    }
}

/// File-level on purpose: closures made here are nonisolated, which matters because
/// KVO callbacks arrive on whatever thread AVFoundation picks.
private func observeFailures(of looper: AVPlayerLooper, item: AVPlayerItem,
                             report: @escaping @Sendable () -> Void) -> [NSKeyValueObservation] {
    [
        looper.observe(\.status) { observed, _ in if observed.status == .failed { report() } },
        item.observe(\.status) { observed, _ in if observed.status == .failed { report() } },
    ]
}

/// Fires for the first and every later item of the queue (AVPlayerLooper swaps items in and out).
private func observeCurrentItem(of player: AVQueuePlayer,
                                changed: @escaping @Sendable () -> Void) -> NSKeyValueObservation {
    player.observe(\.currentItem, options: [.initial, .new]) { _, _ in changed() }
}

private func observeStatus(of item: AVPlayerItem, changed: @escaping @Sendable () -> Void) -> NSKeyValueObservation {
    item.observe(\.status) { _, _ in changed() }
}

private func observeReadiness(of layer: AVPlayerLayer, ready: @escaping @Sendable () -> Void) -> NSKeyValueObservation {
    layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { observed, _ in
        if observed.isReadyForDisplay { ready() }
    }
}

@MainActor final class WallpaperWindowManager {
    private static let pauseWhenOccluded = true
    // A fully covered display needs no decoder: the player (the biggest allocation) is released after this long.
    private static let releaseDelay: UInt64 = 10_000_000_000

    var onPlaybackFailure: (@MainActor (URL) -> Void)?
    /// The video's first frame is in the window; fired once per `show`.
    var onReady: (@MainActor () -> Void)?
    private(set) var currentURL: URL?
    var isShowing: Bool { currentURL != nil }
    /// The window, for transitions.
    var surface: TransitionWindow { windows }

    private let windows: DisplayWindow<PlayerView>
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?  // looping silently stops if this is released
    private var statusObservations: [NSKeyValueObservation] = []
    private var itemObservation: NSKeyValueObservation?  // the current item, until its tracks are known
    /// The wallpaper's options, the master volume and the app's mute (LibraryState.masterVolume, .muted).
    private var options = WallpaperOptions.standard
    private var masterVolume = 1.0
    private var appMuted = false
    /// Silent: the wallpaper or the whole app is muted.
    private var muted: Bool { appMuted || options.muted }
    /// The video's pixel size, once its track has been read.
    private var videoSize: CGSize?
    private let grader = VideoGrader()
    /// Grades the frames while the colour options or the image filter change the picture; built once per video.
    private var composition: AVVideoComposition?
    private var compositionTask: Task<Void, Never>?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var wakeTask: Task<Void, Never>?
    private var releaseTask: Task<Void, Never>?
    private var resumeTime: CMTime?  // where the released player was, for its replacement
    private var failureReported = false
    private var readyReported = false
    private var userPaused = false
    private var occluded = false
    private var sleeping = false
    private var screenLocked = false  // nothing plays under the lock screen, not even sound
    private var playerReleased = false  // the windows stay (black) while the player is gone

    init(displayID: String) {
        windows = DisplayWindow(displayID: displayID) { PlayerView(frame: .zero) }
        windows.onChange = { [weak self] in self?.windowsChanged() }
    }

    func show(url: URL) {
        if currentURL == url { return }
        currentURL = url
        failureReported = false
        readyReported = false
        resumeTime = nil  // a new video starts from its beginning
        videoSize = nil
        composition = nil
        compositionTask?.cancel()
        compositionTask = nil
        loadVideoSize(of: url)
        if observers.isEmpty { installObservers() }
        if !windows.isOpen {
            windows.open()
            windowsChanged()
        }
        // While the display is covered the new video only starts once it is uncovered (restorePlayerIfReleased).
        if !playerReleased { startPlayer(for: url) }
    }

    func hide() {
        compositionTask?.cancel()
        compositionTask = nil
        composition = nil
        wakeTask?.cancel()
        wakeTask = nil
        releaseTask?.cancel()
        releaseTask = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        tearDownPlayer()
        attachPlayer()  // detach from the layers so nothing keeps the old player alive
        windows.close()
        currentURL = nil
        readyReported = false
        // A stopped wallpaper is never user-paused, so the next show() starts playing.
        userPaused = false
        occluded = false
        sleeping = false
        playerReleased = false
        resumeTime = nil
    }

    func setPaused(_ paused: Bool) {
        userPaused = paused
        applyPlayback()
    }

    /// The wallpaper's options (Wallpaper Engine's: volume, mute, playback rate, alignment, flip, colour options,
    /// image filter), the master volume and the app's mute. While silent the audio tracks are disabled, so the audio
    /// decoder idles.
    func apply(_ options: WallpaperOptions, masterVolume: Double, appMuted: Bool) {
        let old = (options: self.options, volume: self.masterVolume, muted: muted)
        self.options = options
        self.masterVolume = masterVolume
        self.appMuted = appMuted
        if old.options.volume != options.volume || old.volume != masterVolume || old.muted != muted {
            player?.volume = Float(options.volume * masterVolume)
            player?.isMuted = muted
            syncAudioTracks()
        }
        if old.options.rate != options.rate { applyRate() }
        windows.view?.look = videoSize.map { (options, $0) }
        applyGrade()
    }

    func setScreenLocked(_ locked: Bool) {
        screenLocked = locked
        applyPlayback()
    }

    func revealSystemWallpaper() { windows.revealSystemWallpaper() }

    // MARK: Windows

    /// The window opened or followed a screen change; a new window starts without the player.
    private func windowsChanged() {
        occluded = false  // new windows report their real state through the occlusion notification
        attachPlayer()
        applyPlayback()
        restorePlayerIfReleased()
    }

    private func attachPlayer() {
        windows.view?.player = player
        windows.view?.look = videoSize.map { (options, $0) }
        windows.view?.onReadyForDisplay = { [weak self] in self?.pictureReady() }
    }

    private func pictureReady() {
        guard currentURL != nil, player != nil, !readyReported else { return }
        readyReported = true
        onReady?()
    }

    /// Reads the size the video is shown at (its track's size, turned by its transform) for the alignment.
    private func loadVideoSize(of url: URL) {
        Task { @MainActor [weak self] in
            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, transform) = try? await track.load(.naturalSize, .preferredTransform)
            else { return }
            let turned = size.applying(transform)
            guard let self, self.currentURL == url else { return }
            self.videoSize = CGSize(width: abs(turned.width), height: abs(turned.height))
            self.windows.view?.look = self.videoSize.map { (self.options, $0) }
        }
    }

    /// The playback rate applies to the next `play()` and, while playing, at once.
    private func applyRate() {
        guard let player else { return }
        player.defaultRate = Float(options.rate)
        if player.rate != 0 { player.rate = Float(options.rate) }
    }

    /// Frames go through the grader only while it changes them; the composition is built the first time.
    private func applyGrade() {
        guard grader.update(options) else {
            setComposition(nil)
            return
        }
        if let composition {
            setComposition(composition)
            return
        }
        guard compositionTask == nil, let url = currentURL else { return }
        let grader = grader
        compositionTask = Task { @MainActor [weak self] in
            let built = try? await AVVideoComposition(applyingFiltersTo: AVURLAsset(url: url)) { request in
                let graded = grader.apply(request.sourceImage).cropped(to: request.sourceImage.extent)
                return AVCIImageFilteringResult(resultImage: graded, ciContext: VideoGrader.context)
            }
            guard let self, !Task.isCancelled, self.currentURL == url else { return }
            self.compositionTask = nil
            // Without a composition the frames stay as they are; the next change of the options tries again.
            guard let built else {
                NSLog("WallpaperMage: colour options unavailable for this video")
                return
            }
            self.composition = built
            self.applyGrade()
        }
    }

    /// Every item the looper plays gets `composition` (nil: frames as they are).
    private func setComposition(_ composition: AVVideoComposition?) {
        for item in looper?.loopingPlayerItems ?? [] where item.videoComposition !== composition {
            item.videoComposition = composition
        }
    }

    // MARK: Player

    private func startPlayer(for url: URL) {
        let queue = AVQueuePlayer()
        queue.isMuted = muted
        queue.volume = Float(options.volume * masterVolume)
        queue.defaultRate = Float(options.rate)
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.allowsExternalPlayback = false
        let item = AVPlayerItem(url: url)
        let newLooper = AVPlayerLooper(player: queue, templateItem: item)
        let report: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.reportFailure(for: url) }
        }
        let observations = observeFailures(of: newLooper, item: item, report: report)

        tearDownPlayer()  // the old player goes only after its replacement exists
        player = queue
        looper = newLooper
        statusObservations = observations + [observeCurrentItem(of: queue) { [weak self] in
            Task { @MainActor [weak self] in self?.syncAudioTracks() }
        }]
        playerReleased = false
        releaseTask?.cancel()  // it belonged to the player that was just replaced
        releaseTask = nil
        if let time = resumeTime {
            queue.seek(to: time)
            resumeTime = nil
        }
        attachPlayer()
        applyGrade()
        applyPlayback()
        if occluded { scheduleRelease() }
    }

    // The tracks exist once the item is ready; until then the status is watched.
    private func syncAudioTracks() {
        itemObservation = nil
        guard let item = player?.currentItem else { return }
        guard item.status == .readyToPlay else {
            itemObservation = observeStatus(of: item) { [weak self] in
                Task { @MainActor [weak self] in self?.syncAudioTracks() }
            }
            return
        }
        let silent = muted || options.volume * masterVolume == 0
        for track in item.tracks where track.assetTrack?.mediaType == .audio { track.isEnabled = !silent }
    }

    private func tearDownPlayer() {
        statusObservations.forEach { $0.invalidate() }
        statusObservations.removeAll()
        itemObservation = nil
        looper?.disableLooping()
        player?.pause()
        player?.removeAllItems()
        looper = nil
        player = nil
    }

    /// Frees the decoder while the display is covered; updateOcclusion() builds a new player when it is uncovered.
    private func releasePlayer() {
        releaseTask = nil
        resumeTime = player?.currentTime()
        tearDownPlayer()
        attachPlayer()
        playerReleased = true
    }

    private func scheduleRelease() {
        guard releaseTask == nil, player != nil else { return }
        releaseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: Self.releaseDelay) } catch { return }
            self?.releasePlayer()
        }
    }

    /// Ends a pending release and brings back a released player, unless the machine is asleep (wake rebuilds it).
    private func restorePlayerIfReleased() {
        releaseTask?.cancel()
        releaseTask = nil
        if playerReleased, !sleeping, let url = currentURL { startPlayer(for: url) }
    }

    private func reportFailure(for url: URL) {
        guard url == currentURL, !failureReported else { return }
        failureReported = true
        onPlaybackFailure?(url)
    }

    /// Plays only when neither the user nor the manager itself (sleep, occlusion) wants it paused.
    private func applyPlayback() {
        if userPaused || sleeping || screenLocked || (Self.pauseWhenOccluded && occluded) {
            player?.pause()
        } else {
            player?.play()
        }
    }

    // MARK: System events

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter
        listen(NSWindow.didChangeOcclusionStateNotification) { $0.updateOcclusion() }
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            listen(name, on: workspace) { $0.pauseForSleep() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            listen(name, on: workspace) { $0.scheduleWakeRebuild() }
        }
    }

    private func listen(_ name: Notification.Name, on center: NotificationCenter = .default,
                        _ handler: @escaping @MainActor @Sendable (WallpaperWindowManager) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // Nothing from the Notification is sent along; handlers re-read live state instead.
            Task { @MainActor [weak self] in
                if let self { handler(self) }
            }
        }
        observers.append((center, token))
    }

    private func updateOcclusion() {
        occluded = windows.window.map { !$0.occlusionState.contains(.visible) } ?? false
        if occluded { scheduleRelease() } else { restorePlayerIfReleased() }
        applyPlayback()
    }

    private func pauseForSleep() {
        wakeTask?.cancel()
        wakeTask = nil
        sleeping = true
        applyPlayback()
    }

    /// didWake and screensDidWake both fire; re-arming keeps it to one rebuild, after displays settle.
    private func scheduleWakeRebuild() {
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            self?.finishWake()
        }
    }

    private func finishWake() {
        wakeTask = nil
        sleeping = false
        occluded = false
        guard let url = currentURL else { return }
        startPlayer(for: url)
    }
}
