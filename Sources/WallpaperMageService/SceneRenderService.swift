import AppKit
import Core
import IOKit.ps
import SceneBridge

// A scene on one display. Our own renderer (SceneRenderer/, a Rust library) draws it with Metal into the
// CAMetalLayer of the display's window, with that display's settings (DisplayConfig) or its playlist's.

/// One Rust renderer, on its way from the loading thread to the main actor.
final class RendererBox: @unchecked Sendable {
    let renderer: Renderer
    init(_ renderer: Renderer) { self.renderer = renderer }
}

@MainActor final class SceneRenderService: WallpaperService {
    /// A scene that has not drawn within this long after loading is shown anyway.
    private static let readyTimeout = 3.0
    private var renderer: Renderer?
    private let windows: DisplayWindow<MetalView>
    private let power = PowerSource()
    private var audio: SystemAudioTap?
    private var pointerMonitor: Any?
    private var generation = 0
    /// The renderer has drawn its first frame. Until then it runs (silently) even on a paused display, so the window
    /// has a picture to show.
    private var drawn = false
    private var firstFrame: Task<Void, Never>?
    // What the renderer has been given so far; nil = nothing yet, so everything is pushed.
    private var appliedOptions: WallpaperOptions?
    private var appliedVolume: Double?
    private var appliedSilent: Bool?
    private var appliedFPS: Int?
    private var appliedScale: Double?
    private var appliedPaused: Bool?
    private var paused = false
    /// The display the renderer draws on, as it was attached.
    private var attached: SceneDisplay?

    override init(displayID: String) {
        windows = DisplayWindow(displayID: displayID) { MetalView(frame: .zero) }
        super.init(displayID: displayID)
        windows.onChange = { [weak self] in self?.attachDisplay() }
        power.onChange = { [weak self] in
            guard let self, let item = self.item, self.renderer != nil else { return }
            self.push(item)
        }
    }

    override var surface: TransitionWindow? { windows }

    /// The settings changed (or a scene is about to start): push only what differs.
    override func update(_ state: LibraryState) {
        super.update(state)
        guard renderer != nil, let item else { return }
        push(item)
    }

    override func start(_ item: VideoItem) {
        stopRenderer()
        super.start(item)
        generation += 1
        let mine = generation
        // Loading a scene takes a moment, so it happens off the main actor.
        let path = item.url.path
        // Scripts keep their localStorage in the wallpaper's own library folder, which goes with the wallpaper.
        let storage = AppPaths.isInsideLibrary(item.url)
            ? item.url.deletingLastPathComponent().appendingPathComponent("scenescript-storage.json").path : nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let box: Result<RendererBox, Swift.Error>
            do {
                box = .success(RendererBox(try Renderer(pkgPath: path, storagePath: storage)))
            } catch {
                box = .failure(error)
            }
            await MainActor.run { [weak self] in
                self?.loaded(box, item: item, mine: mine)
            }
        }
    }

    private func loaded(_ result: Result<RendererBox, Swift.Error>, item: VideoItem, mine: Int) {
        guard mine == generation else { return }
        switch result {
        case .failure(let error):
            super.stop()
            onFailure?(item, String(localized: "Couldn’t play “\(item.name)”. \(error.localizedDescription)"))
        case .success(let box):
            let renderer = box.renderer
            self.renderer = renderer
            for message in renderer.loadErrors() {
                NSLog("WallpaperMage: \(item.name): \(message)")
            }
            windows.open()
            attachDisplay()
            startPointer()
            push(item)
            awaitFirstFrame(mine)
            reportReady(after: Self.readyTimeout)
        }
    }

    /// Watches the renderer's frame count until its first frame is drawn, then lets the pause and mute apply and tells
    /// the DisplayPlayer. The count rises when the GPU has finished the frame; the frame is shown a moment later, so one
    /// more poll passes before ready is reported.
    private func awaitFirstFrame(_ mine: Int) {
        firstFrame?.cancel()
        firstFrame = Task { @MainActor [weak self] in
            while true {
                do { try await Task.sleep(nanoseconds: 16_000_000) } catch { return }
                guard let self, mine == self.generation, let renderer = self.renderer, let item = self.item else { return }
                if self.drawn {
                    self.reportReady()
                    return
                }
                if renderer.stats().frames > 0 {
                    self.drawn = true
                    self.push(item)
                }
            }
        }
    }

    override func stop() {
        super.stop()
        generation += 1
        stopRenderer()
        windows.close()
    }

    /// Hands the renderer the window's layer. It is attached again only when its layer or size changed (attaching
    /// again replaces it), and detached when the window went away with its screen.
    private func attachDisplay() {
        guard let renderer else { return }
        let display = windows.display()
        guard display != attached else { return }
        if let attached, display == nil { renderer.detachLayer(displayId: attached.id) }
        if let display {
            let pointer = UInt64(UInt(bitPattern: Unmanaged.passUnretained(display.layer).toOpaque()))
            renderer.attachLayer(displayId: display.id, layerPtr: pointer,
                                 width: UInt32(display.pixelWidth), height: UInt32(display.pixelHeight))
        }
        attached = display
    }

    private func stopRenderer() {
        firstFrame?.cancel()
        firstFrame = nil
        drawn = false
        stopPointer()
        if let attached { renderer?.detachLayer(displayId: attached.id) }
        attached = nil
        renderer?.stop()
        renderer = nil
        setAudioCapture(false)
        appliedOptions = nil
        appliedVolume = nil
        appliedSilent = nil
        appliedFPS = nil
        appliedScale = nil
        appliedPaused = nil
    }

    /// The cursor drives parallax: its position on this display goes to the renderer, 0...1 with the origin at the
    /// top-left (held at the edge while the cursor is on another display). A left press on the bare desktop of this
    /// display goes to the scene's scripts, so a clock can be dragged.
    private func startPointer() {
        guard pointerMonitor == nil else { return }
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            // Global monitors run on the main thread.
            MainActor.assumeIsolated { self?.pointerEvent(event.type) }
        }
    }

    private var pressedOnDesktop = false

    private func pointerEvent(_ type: NSEvent.EventType) {
        sendPointer()
        switch type {
        case .leftMouseDown where windows.window?.frame.contains(NSEvent.mouseLocation) == true
                               && Self.isDesktop(at: NSEvent.mouseLocation):
            pressedOnDesktop = true
            renderer?.setPointerDown(down: true)
        case .leftMouseUp where pressedOnDesktop:
            pressedOnDesktop = false
            renderer?.setPointerDown(down: false)
        default:
            break
        }
    }

    /// Whether a click at `point` lands on the desktop rather than on some app's window.
    private static func isDesktop(at point: NSPoint) -> Bool {
        let number = NSWindow.windowNumber(at: point, belowWindowWithWindowNumber: 0)
        guard number > 0,
              let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(number)) as? [[String: Any]],
              let level = info.first?[kCGWindowLayer as String] as? Int
        else { return true }
        return level <= Int(CGWindowLevelForKey(.desktopIconWindow))
    }

    private func stopPointer() {
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
        pressedOnDesktop = false
    }

    private func sendPointer() {
        guard let renderer, let frame = windows.window?.frame else { return }
        let mouse = NSEvent.mouseLocation
        let x = min(max((mouse.x - frame.minX) / frame.width, 0), 1)
        let y = min(max((mouse.y - frame.minY) / frame.height, 0), 1)
        renderer.setPointer(x: Float(x), y: Float(1 - y))
    }

    override func setPaused(_ paused: Bool) {
        self.paused = paused
        if let item, renderer != nil { push(item) }
    }

    /// The lock screen covers the desktop: nothing is drawn and nothing is heard.
    override func setScreenLocked(_ locked: Bool) {
        renderer?.setVisible(visible: !locked)
    }

    override func revealSystemWallpaper() { windows.revealSystemWallpaper() }

    /// Sends the settings that changed since the last push. Battery rules apply here: on battery
    /// (or in Low Power Mode) the scene pauses or runs slower and smaller, as the user chose.
    private func push(_ item: VideoItem) {
        guard let renderer else { return }
        let new = state.options(for: item.id, on: displayID)
        let old = appliedOptions
        let rules = state.config(for: displayID).power
        let saving = power.isSaving
        var fps = new.fps
        var scale = new.renderScale
        if saving && rules.batteryMode == .reducedQuality {
            fps = min(fps, rules.batteryFPS)
            scale = min(scale, rules.batteryRenderScale)
        }
        // A paused scene still draws its first frame, without a sound (`drawn`).
        let holds = paused || (saving && rules.batteryMode == .pause)
        let pause = holds && drawn

        if new.framing != old?.framing {
            renderer.setFraming(framing: new.framing)
        }
        if new.colorGrade != old?.colorGrade {
            renderer.setColorGrade(grade: new.colorGrade)
        }
        if new.rate != old?.rate {
            renderer.setRate(rate: Float(new.rate))
        }
        if new.mouseParallax != old?.mouseParallax {
            renderer.setParallaxEnabled(enabled: new.mouseParallax)
        }
        if new.antialiasing != old?.antialiasing {
            renderer.applyAntialiasing(samples: new.antialiasing ? 4 : 1)
        }
        if scale != appliedScale {
            renderer.setRenderScale(scale: Float(scale))
        }
        let volume = new.volume * state.masterVolume
        if volume != appliedVolume {
            renderer.setVolume(volume: Float(volume))
        }
        let silent = state.muted || new.muted || (holds && !drawn)
        if silent != appliedSilent {
            renderer.setMuted(muted: silent)
        }
        if new.audioResponse != old?.audioResponse {
            renderer.setAudioResponse(enabled: new.audioResponse)
        }
        for (key, value) in new.properties where old?.properties[key] != value {
            renderer.applyProperty(name: key, valueJson: value.json)
        }
        if fps != appliedFPS {
            renderer.setFpsCap(fps: Float(fps))
        }
        if pause != appliedPaused {
            if pause { renderer.pause() } else { renderer.play() }
        }
        setAudioCapture(new.audioResponse && !pause)
        appliedOptions = new
        appliedVolume = volume
        appliedSilent = silent
        appliedFPS = fps
        appliedScale = scale
        appliedPaused = pause
    }

    /// System audio is captured only while a playing scene asks for audio response.
    private func setAudioCapture(_ on: Bool) {
        if on, audio == nil, let renderer {
            let tap = SystemAudioTap()
            tap.onSpectrum = { left, right in renderer.setAudioSpectrum(left: left, right: right) }
            do {
                try tap.start()
                audio = tap
            } catch {
                NSLog("WallpaperMage: audio response unavailable: \(error)")
            }
        } else if !on, let tap = audio {
            tap.stop()
            audio = nil
        }
    }
}

/// Whether the Mac runs on battery or in Low Power Mode, with a callback when that changes.
@MainActor private final class PowerSource {
    var onChange: (() -> Void)?
    private(set) var isSaving = PowerSource.current()
    // Only touched by init and deinit, both on the main thread: the run loop source's callback holds an unretained
    // pointer to self, so deinit must take the source off the run loop before self goes.
    nonisolated(unsafe) private var source: CFRunLoopSource?
    nonisolated(unsafe) private var token: NSObjectProtocol?

    init() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let me = Unmanaged<PowerSource>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { me.refresh() }
        }, context)?.takeRetainedValue()
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode) }
        token = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
        if let token { NotificationCenter.default.removeObserver(token) }
    }

    private func refresh() {
        let now = Self.current()
        guard now != isSaving else { return }
        isSaving = now
        onChange?()
    }

    private static func current() -> Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}

extension WallpaperOptions {
    /// Where and how big the renderer draws the scene.
    var framing: Framing {
        Framing(alignment: alignment.renderer, position: Float(position), x: Float(alignX), y: Float(alignY),
                zoom: Float(zoom), flip: flip, blurBars: blurBars && alignment.canLeaveBars)
    }

    /// The renderer's colour options and image filter.
    var colorGrade: ColorGrade {
        ColorGrade(adjust: colorAdjust, brightness: Float(brightness), contrast: Float(contrast),
                   saturation: Float(saturation), hue: Float(hue), filter: filter ?? "",
                   filterStrength: Float(filterStrength))
    }
}

extension WallpaperAlignment {
    var renderer: Alignment {
        switch self {
        case .cover: return .cover
        case .fill: return .fill
        case .center: return .center
        case .stretch: return .stretch
        case .free: return .free
        }
    }
}

extension ScenePropertyValue {
    /// The renderer takes JSON: a number, a string or "r g b" for a colour.
    var json: String {
        switch self {
        case .bool(let v): return v ? "true" : "false"
        case .number(let v): return String(v)
        case .string(let v):
            let data = try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        case .color(let r, let g, let b): return "\"\(r) \(g) \(b)\""
        }
    }
}
