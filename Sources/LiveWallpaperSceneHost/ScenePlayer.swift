import AppKit
import Core
import Metal
import SceneFormat
import SceneEngine

// Owner: SCENERENDER. The live desktop player of the scene host: one borderless window per screen at the same
// level as the agent's video windows (desktop window level + 1, all Spaces, ignores mouse), each with a
// CAMetalLayer that a SceneRenderer draws into. Frame pump: a timer at `fpsCap`, stopped while the desktop is
// covered (occlusion), paused by the user, or the display sleeps. Pointer position for parallax comes from
// NSEvent.mouseLocation (no permission needed). Contract with HostMain: SPEC3.md section 3.5.

@MainActor final class ScenePlayerWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func becomeKey() {}
    override func becomeMain() {}
    override func resignKey() {}
    override var acceptsFirstResponder: Bool { false }
}

@MainActor final class ScenePlayer {
    /// Called when the state changes (HostMain turns it into a HostStatus).
    var onChange: (@MainActor (HostStatus.SceneState, String?) -> Void)?
    private(set) var state: HostStatus.SceneState = .none
    private(set) var itemID: UUID?

    @MainActor private final class ScreenSlot {
        let screen: NSScreen
        let window: ScenePlayerWindow
        let layer: CAMetalLayer
        init(screen: NSScreen, device: MTLDevice?) {
            self.screen = screen
            let width = max(1, Int(screen.frame.width * screen.backingScaleFactor))
            let height = max(1, Int(screen.frame.height * screen.backingScaleFactor))
            let layer = CAMetalLayer()
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.drawableSize = CGSize(width: width, height: height)
            layer.isOpaque = true
            layer.backgroundColor = CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            components: [0, 0, 0, 1])
            self.layer = layer
            let window = ScenePlayerWindow(contentRect: screen.frame, styleMask: .borderless,
                                           backing: .buffered, defer: false)
            // Same level as the agent's video windows (WallpaperWindows): desktop level + 1. The shielding
            // level would sit above every other window incl. the menu bar and lock the whole screen out.
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)
            window.backgroundColor = .black
            window.isOpaque = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.ignoresMouseEvents = true
            let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.wantsLayer = true
            view.layer = layer  // CALayer cannot be assigned to two views at once; each slot has its own
            window.contentView = view
            self.window = window
            // OrderOut/OrderFront continuity: order front without taking focus at all.
            window.orderFrontRegardless()
        }
    }

    private var slots: [ScreenSlot] = []
    private var engine: SceneRenderer?
    private var commandQueue: MTLCommandQueue?
    private var device: MTLDevice?
    private var fpsCap = 30
    private var pump: Timer?
    private var playStart: Date = Date()
    private var pausedOffset: Double = 0
    private var isPaused = false
    private var generation = 0        // invalidates in-flight async loads when the scene changes
    private var observedFailureOnce = false
    private let runner = WPEngineRunner()

    init() {}

    /// Loads the scene (SceneLoader), builds renderers, opens the windows and starts the pump. Reports `.loading`,
    /// then `.playing` after the first frame was presented; `.fallbackStill` when only the preview image can be
    /// shown (analysis.support == .previewOnly, or a load/shader/texture error); `.failed` when not even that works.
    func show(itemID: UUID, scenePath: URL, previewPath: URL?, assetsPath: URL?, fpsCap: Int) {
        self.itemID = itemID
        generation += 1
        let current = generation
        // .loading only: no windows yet. The agent keeps its own wallpaper up until it receives .playing
        // (or .fallbackStill), so a slow load or an unreadable scene can never black out or lock the desktop.
        setState(.loading, nil)
        setFPSCap(fpsCap)

        // The ported engine draws everything (effects, particles, puppets); the Metal path below is the fallback.
        tearDownVisuals()
        // Armed only once the engine survived its start: an exit in the first seconds (e.g. no shared assets) must
        // reach the Metal fallback below, not be reported as a failure.
        runner.onUnexpectedExit = nil
        if runner.start(projectFolder: scenePath.deletingLastPathComponent(), assets: assetsPath, fps: fpsCap) {
            Task { @MainActor [weak self] in
                // A scene the engine cannot load exits within a moment; only then is it playing.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, current == self.generation else { return }
                if self.runner.isRunning {
                    self.runner.onUnexpectedExit = { [weak self] in
                        guard let self, current == self.generation else { return }
                        self.setState(.failed, "the scene engine stopped unexpectedly")
                    }
                    self.setState(self.isPaused ? .paused : .playing, nil)
                } else {
                    self.showWithMetal(itemID: itemID, scenePath: scenePath, previewPath: previewPath,
                                       assetsPath: assetsPath, current: current)
                }
            }
            return
        }
        showWithMetal(itemID: itemID, scenePath: scenePath, previewPath: previewPath, assetsPath: assetsPath,
                      current: current)
    }

    private func showWithMetal(itemID: UUID, scenePath: URL, previewPath: URL?, assetsPath: URL?, current: Int) {

        Task { @MainActor [weak self] in
            guard let self, current == self.generation else { return }
            do {
                let loaded: LoadedScene
                if scenePath.pathExtension.lowercased() == "pkg" {
                    loaded = try SceneLoader.load(packageAt: scenePath, sharedAssets: assetsPath)
                } else {
                    loaded = try SceneLoader.load(directory: scenePath, sharedAssets: assetsPath)
                }
                guard current == self.generation else { return }
                guard self.ensureDevice() != nil else { return self.failedToMount(current, previewPath, "no Metal device") }
                let options = RenderOptions(pixelWidth: 0, pixelHeight: 0, pixelFormat: .bgra8Unorm,
                                            textureBudgetBytes: 400 * 1024 * 1024, fitMode: .fill)
                let renderer = try SceneRenderer(scene: loaded, device: self.device!, options: fillOptions(options))
                try renderer.prepare()
                guard current == self.generation else { renderer.releaseGPUResources(); return }
                self.openWindows()
                self.replaceLoaded(renderer: renderer)
                self.setState(.playing, nil)
            } catch {
                guard current == self.generation else { return }
                self.fallbackStill(previewPath, reason: error.localizedDescription)
            }
        }
    }

    /// Windows off, pump stopped, GPU resources freed (windows only when `dropWindows`).
    private func tearDownVisuals() {
        runner.onUnexpectedExit = nil
        runner.stop()
        stopPump()
        for slot in slots { slot.window.orderOut(nil) }
        slots.removeAll()
        engine?.releaseGPUResources()
        engine = nil
    }

    /// Nothing renderable at all (not even the preview image): close everything and report failure so
    /// the agent brings its own wallpaper back.
    private func failedToMount(_ generationAtStart: Int, _ previewPath: URL?, _ reason: String) {
        guard generation == generationAtStart else { return }
        tearDownVisuals()
        setState(.failed, reason)
    }

    /// Closes the windows, drops every GPU resource, stops the pump.
    func hide() {
        generation += 1
        tearDownVisuals()
        commandQueue = nil
        itemID = nil
        setState(.none, nil)
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        runner.setPaused(paused)
        if paused {
            pausedOffset = elapsedSceneTime()   // freeze the scene clock where it is
        } else {
            playStart = Date()                  // resume from the frozen offset
        }
        var message: String? = nil
        if paused, state == .playing { setState(.paused, message) }
        else if !paused, state == .paused { setState(.playing, message) }
        message = nil
        _ = message
        restartPumpIfNeeded()
    }

    func setMuted(_ muted: Bool) {}   // M0 has no audio; the flag is kept for M3

    func setFPSCap(_ fps: Int) {
        fpsCap = max(1, min(fps, 240))
        if pump != nil, !isPaused { restartDrain() }
    }

    // MARK: Window setup

    /// The GPU device/queue live for the whole host; windows are created fresh whenever something must show.
    private func ensureDevice() -> MTLDevice? {
        if device == nil {
            device = SceneRenderer.deviceDefault()
            commandQueue = device?.makeCommandQueue()
        }
        return commandQueue != nil ? device : nil
    }

    private func openWindows() {
        guard ensureDevice() != nil else { return }
        for old in slots { old.window.orderOut(nil) }
        slots = NSScreen.screens.map { ScreenSlot(screen: $0, device: device!) }
    }

    private func fillOptions(_ options: RenderOptions) -> RenderOptions {
        guard ensureDevice() != nil, let biggest = slots.map(\.layer).max(by: {
            $0.drawableSize.width * $0.drawableSize.height < $1.drawableSize.width * $1.drawableSize.height
        }) else { return options }
        return RenderOptions(pixelWidth: Int(biggest.drawableSize.width),
                             pixelHeight: Int(biggest.drawableSize.height),
                             pixelFormat: options.pixelFormat,
                             textureBudgetBytes: options.textureBudgetBytes,
                             fitMode: options.fitMode)
    }

    private func replaceLoaded(renderer: SceneRenderer) {
        engine?.releaseGPUResources()
        engine = renderer
        observedFailureOnce = false
        playStart = Date()
        pausedOffset = 0
        isPaused = false
        startPump()
    }

    private func fallbackStill(_ previewPath: URL?, reason: String) {
        if let previewPath, ensureDevice() != nil,
           let image = Self.previewImage(from: previewPath) {
            let options = RenderOptions(pixelWidth: 0, pixelHeight: 0, pixelFormat: .bgra8Unorm,
                                        textureBudgetBytes: 16 * 1024 * 1024, fitMode: .fill)
            do {
                let still = try SceneRenderer(previewImage: image, device: device!, options: fillOptions(options))
                try still.prepare()
                openWindows()
                replaceLoaded(renderer: still)
                setState(.fallbackStill, reason)
                return
            } catch {
                setState(.failed, "\(reason); the preview image could not be shown either (\(error.localizedDescription))")
                return
            }
        }
        setState(.failed, reason)
    }

    private static func previewImage(from url: URL) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    // MARK: Frame pump

    private func startPump() {
        guard pump == nil else { return }
        restartDrain()
    }

    private func restartDrain() {
        stopPump()
        let interval = 1.0 / Double(fpsCap)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pump = timer
    }

    private func stopPump() {
        pump?.invalidate()
        pump = nil
    }

    private func restartPumpIfNeeded() {
        if engine != nil, !isPaused {
            restartDrain()
        }
    }

    private func tick() {
        // Frame pump duty cycle (SPEC3 3.5): skip when paused, the display sleeps, or no covered screen shows.
        guard !isPaused, let engine, let queue = commandQueue else { return }
        guard !Self.displayIsAsleep() else { return }
        var visible = false
        for slot in slots where slot.window.occlusionState.contains(.visible) {
            visible = true
        }
        guard visible else { return }

        let time = elapsedSceneTime()
        let parallax = currentParallax()
        var succeeded = true
        for slot in slots {
            guard slot.window.occlusionState.contains(.visible),
                  let drawable = slot.layer.nextDrawable(), let buffer = queue.makeCommandBuffer() else { continue }
            do {
                try engine.encode(at: time, parallax: parallax, into: drawable.texture, commandBuffer: buffer)
                buffer.present(drawable)
                buffer.commit()
            } catch {
                succeeded = false
            }
        }
        if !succeeded, !observedFailureOnce {
            observedFailureOnce = true
            // Encoding never fails on resources for good; keep the windows black rather than state-failing the host.
        }
    }

    private func elapsedSceneTime() -> Double {
        guard engine != nil else { return 0 }
        var elapsed = pausedOffset
        if !isPaused {
            elapsed += Date().timeIntervalSince(playStart)
        }
        return max(0, elapsed)
    }

    private func currentParallax() -> ParallaxInput {
        // NSEvent.mouseLocation is the global flurb (bottom-left origin); normalise it seatless [-1, 1] fist through
        // the bounds of one virtual desktop that spans every screen.
        let mouse = NSEvent.mouseLocation
        var left = CGFloat.greatestFiniteMagnitude
        var bottom = CGFloat.greatestFiniteMagnitude
        var right = -CGFloat.greatestFiniteMagnitude
        var top = -CGFloat.greatestFiniteMagnitude
        for screen in NSScreen.screens {
            let frame = screen.frame
            left = min(left, frame.minX)
            bottom = min(bottom, frame.minY)
            right = max(right, frame.maxX)
            top = max(top, frame.maxY)
        }
        let width = max(1, right - left)
        let height = max(1, top - bottom)
        let x = Float(((mouse.x - left) / width) * 2 - 1)
        let y = Float(((mouse.y - bottom) / height) * 2 - 1)
        return ParallaxInput(x: max(-1, min(1, x)), y: max(-1, min(1, y)))
    }

    private static func displayIsAsleep() -> Bool {
        CGDisplayIsAsleep(CGMainDisplayID()) != 0
    }

    // MARK: State

    private func setState(_ new: HostStatus.SceneState, _ message: String?) {
        state = new
        onChange?(new, message)
    }
}

extension SceneRenderer {
    /// The default Metal device for the live player (nil when this Mac has no discrete/integrated GPU).
    static func deviceDefault() -> MTLDevice? {
        MTLCreateSystemDefaultDevice()
    }
}
