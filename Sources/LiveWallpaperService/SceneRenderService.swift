import AppKit
import Core
import RenderBridge
import SceneBridge

// Scenes on the desktop. Two renderers live here while the new one is being tried out: the old
// bridge (RenderService, see docs/render-bridge-notes.md) and our own (SceneRenderer/, a Rust
// library that draws with Metal). The library state picks which one draws, so the user can
// compare them on the same scene.

/// One Rust renderer, for the old bridge: created on first use, after the environment it reads is set.
@MainActor enum LegacyBridge {
    private static var bridge: WallpaperBridge?
    private static var bootstrapped = false

    static func shared() throws -> WallpaperBridge {
        if let bridge { return bridge }
        configureEnvironment()
        let made = try WallpaperBridge()
        bridge = made
        return made
    }

    /// Runs `bootstrap` once. It also re-opens whatever the renderer had assigned last time.
    static func bootstrapIfNeeded(_ bridge: WallpaperBridge) async throws {
        guard !bootstrapped else { return }
        _ = try await bridge.bootstrap()
        bootstrapped = true
    }

    private static func configureEnvironment() {
        let support = AppPaths.supportDirectory.appendingPathComponent("RenderService", isDirectory: true)
        setenv("WALLPAPER_MACHINE_SUPPORT_ROOT", support.path, 1)
        setenv("WALLPAPER_MACHINE_USER_ASSETS_ROOT", support.appendingPathComponent("UserAssets").path, 1)
        setenv("WALLPAPER_MACHINE_LIBRARY_ROOT", AppPaths.libraryDirectory.path, 1)
        setenv("WALLPAPER_MACHINE_ASSETS_ROOT", AppPaths.sharedAssetsDirectory.path, 1)
        // MoltenVK for the Vulkan scene path: the copy shipped inside the bundle (build.sh) when there is one,
        // else Homebrew's for a dev build.
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/MoltenVK_icd.json").path,
            "/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json",
        ]
        if getenv("VK_ICD_FILENAMES") == nil, let icd = candidates.first(where: FileManager.default.fileExists(atPath:)) {
            setenv("VK_ICD_FILENAMES", icd, 1)
        }
    }
}

/// One Rust renderer, on its way from the loading thread to the main actor.
private final class RendererBox: @unchecked Sendable {
    let renderer: Renderer
    init(_ renderer: Renderer) { self.renderer = renderer }
}

/// Scenes on the desktop, drawn by the old bridge or by our own renderer.
@MainActor final class SceneRenderService: WallpaperService {
    static let notConnected = "Scene renderer not connected yet."

    private let legacy = LegacySceneRenderer()
    private let modern = ModernSceneRenderer()
    private var state = LibraryState()

    override init() {
        super.init()
        legacy.onReady = { [weak self] item in self?.onReady?(item) }
        legacy.onFailure = { [weak self] item, message in self?.onFailure?(item, message) }
        modern.onReady = { [weak self] item in self?.onReady?(item) }
        modern.onFailure = { [weak self] item, message in self?.onFailure?(item, message) }
    }

    /// The Orchestrator's state changed (or a scene is about to start): push only what differs to
    /// the running scene.
    func update(_ state: LibraryState) {
        self.state = state
        if state.useNewRenderer {
            modern.update(state)
        } else {
            legacy.update(state)
        }
    }

    override func start(_ item: VideoItem) {
        super.start(item)
        if state.useNewRenderer {
            modern.start(item)
        } else {
            legacy.start(item)
        }
    }

    override func stop() {
        super.stop()
        if state.useNewRenderer {
            modern.stop()
        } else {
            legacy.stop()
        }
    }

    override func setPaused(_ paused: Bool) {
        if state.useNewRenderer {
            modern.setPaused(paused)
        } else {
            legacy.setPaused(paused)
        }
    }

    override func setMuted(_ muted: Bool) {
        if state.useNewRenderer {
            modern.setMuted(muted)
        } else {
            legacy.setMuted(muted)
        }
    }

    override func setScreenLocked(_ locked: Bool) {
        if state.useNewRenderer {
            modern.setScreenLocked(locked)
        } else {
            legacy.setScreenLocked(locked)
        }
    }
}

/// The old renderer behind its bridge. It draws the scene itself, in windows of its own.
@MainActor final class LegacySceneRenderer {
    var onReady: (@MainActor (VideoItem) -> Void)?
    var onFailure: (@MainActor (VideoItem, String?) -> Void)?

    /// Library folder name of the scene (`Library/<id>/project.json`).
    private var wallpaperID: String?
    private var displayIDs: [String] = []
    private var muted = true
    private var generation = 0
    private var state = LibraryState()
    private var item: VideoItem?
    // What the renderer has been given so far; nil = nothing yet, so everything is pushed.
    private var appliedScene: SceneOptions?
    private var appliedPower: PowerOptions?
    private var appliedFPS: Int?
    private var pushChain: Task<Void, Never>?

    /// The Orchestrator's state changed (or a scene is about to start): push only what differs.
    func update(_ state: LibraryState) {
        self.state = state
        guard let id = wallpaperID, !displayIDs.isEmpty else { return }
        push(id)
    }

    private var sceneOptions: SceneOptions { item.flatMap { state.sceneOptions[$0.id.uuidString] } ?? .standard }

    /// Sends the settings that changed since the last push. Calls are chained so two quick edits keep their order,
    /// and every bridge call is `try?`: a refused setting must not stop the others or the scene.
    private func push(_ id: String) {
        let new = sceneOptions, power = state.power, fps = new.fps ?? state.sceneFPS
        let oldScene = appliedScene, oldPower = appliedPower, oldFPS = appliedFPS
        appliedScene = new; appliedPower = power; appliedFPS = fps
        let displays = displayIDs
        let previous = pushChain
        pushChain = Task { @MainActor in
            await previous?.value
            guard let bridge = try? LegacyBridge.shared() else { return }
            // Global (all scenes, all displays). Battery rule: the renderer watches the power source itself.
            if power != oldPower {
                _ = try? await bridge.setFrameRateCap(cap: power.frameRateCap.map { UInt32(max($0, 1)) })
                _ = try? await bridge.setSceneOptimizationEnabled(enabled: power.skipRepeatedFrames)
                _ = try? await bridge.setSceneOnDemandEnabled(enabled: power.renderOnlyOnChange)
                _ = try? await bridge.setBatteryQualityProfile(renderScale: Float(power.batteryRenderScale), targetFps: UInt32(power.batteryFPS))
                _ = try? await bridge.setBatteryMode(mode: power.batteryMode.bridge)
            }
            // shortcut: the bridge has one render scale for all scenes; only one scene runs at a time, so this is the scene's.
            if new.renderScale != oldScene?.renderScale { _ = try? await bridge.setRenderScale(scale: Float(new.renderScale)) }
            for display in displays {
                if new.fitMode != oldScene?.fitMode {
                    _ = try? await bridge.setScalingMode(wallpaperId: id, displayId: display, mode: new.fitMode.bridge)
                }
                if new.panX != oldScene?.panX || new.panY != oldScene?.panY {
                    _ = try? await bridge.setDisplayPosition(wallpaperId: id, displayId: display, panX: new.panX, panY: new.panY)
                }
                if new.zoom != oldScene?.zoom { _ = try? await bridge.editScalingFactor(wallpaperId: id, displayId: display, factor: new.zoom) }
                if fps != oldFPS { _ = try? await bridge.setTargetFps(wallpaperId: id, displayId: display, fps: UInt32(fps)) }
            }
            if new.volume != oldScene?.volume { _ = try? await bridge.setVolume(wallpaperId: id, volume: Float(new.volume)) }
            if new.audioResponse != oldScene?.audioResponse {
                _ = try? await bridge.setAudioResponseEnabled(wallpaperId: id, enabled: new.audioResponse)
            }
            var draft = new.zoom != oldScene?.zoom
            for (key, value) in new.properties where oldScene?.properties[key] != value {
                _ = try? await bridge.editProperty(wallpaperId: id, propertyId: key, value: value.bridge)
                draft = true
            }
            if draft { _ = try? await bridge.applyWallpaperOptions(wallpaperId: id, userInitiated: false) }
        }
    }

    func start(_ item: VideoItem) {
        generation += 1
        let mine = generation
        appliedScene = nil; appliedPower = nil; appliedFPS = nil
        self.item = item
        let id = item.url.deletingLastPathComponent().lastPathComponent
        wallpaperID = id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let bridge = try LegacyBridge.shared()
                try await LegacyBridge.bootstrapIfNeeded(bridge)
                let selection = try await bridge.selectWallpaper(id: id)
                guard let options = selection.wallpaperOptions, options.supported else {
                    return self.failed(mine, item, "This scene isn’t supported yet.")
                }
                let displays = options.displayConfigurations.map(\.displayId)
                for display in displays {
                    _ = try await bridge.setDisplayConfigEnabled(wallpaperId: id, displayId: display, enabled: true)
                }
                _ = try await bridge.applyWallpaperOptions(wallpaperId: id, userInitiated: true)
                guard mine == self.generation else { return }   // another item was chosen meanwhile
                self.displayIDs = displays
                let muted = self.muted
                _ = try await bridge.setMuted(wallpaperId: id, muted: muted)
                self.push(id)
                self.onReady?(item)
            } catch {
                self.failed(mine, item, "Couldn’t play “\(item.name)”. \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        generation += 1
        let id = wallpaperID
        let displays = displayIDs
        wallpaperID = nil
        displayIDs = []
        item = nil
        appliedScene = nil; appliedPower = nil; appliedFPS = nil
        guard let id else { return }
        Task { @MainActor in
            guard let bridge = try? LegacyBridge.shared() else { return }
            for display in displays {
                _ = try? await bridge.ejectWallpaperFromDisplay(displayId: display, wallpaperId: id)
            }
        }
    }

    func setPaused(_ paused: Bool) {
        // The renderer pauses every display at once; the Orchestrator's pause is global too.
        Task { @MainActor in
            guard let bridge = try? LegacyBridge.shared() else { return }
            if paused { _ = try? await bridge.pauseAll() } else { _ = try? await bridge.playAll() }
        }
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        guard let id = wallpaperID else { return }
        Task { @MainActor in
            guard let bridge = try? LegacyBridge.shared() else { return }
            _ = try? await bridge.setMuted(wallpaperId: id, muted: muted)
        }
    }

    /// The old renderer keeps drawing behind the lock screen; the windows are covered by it.
    func setScreenLocked(_ locked: Bool) {}

    private func failed(_ generation: Int, _ item: VideoItem, _ message: String) {
        guard generation == self.generation else { return }
        wallpaperID = nil
        displayIDs = []
        onFailure?(item, message)
    }
}

/// Our own renderer: the Rust library in SceneRenderer/ draws the scene with Metal into the
/// CAMetalLayers the app hands over.
@MainActor final class ModernSceneRenderer {
    var onReady: (@MainActor (VideoItem) -> Void)?
    var onFailure: (@MainActor (VideoItem, String?) -> Void)?

    private var renderer: Renderer?
    private let windows = SceneWindowManager()
    private var muted = true
    private var generation = 0
    private var state = LibraryState()
    private var item: VideoItem?
    // What the renderer has been given so far; nil = nothing yet, so everything is pushed.
    private var appliedScene: SceneOptions?
    private var appliedFPS: Int?
    private var paused = false
    private var hidden = false
    /// The displays the renderer draws on.
    private var attached: [String] = []

    /// The Orchestrator's state changed (or a scene is about to start): push only what differs.
    func update(_ state: LibraryState) {
        self.state = state
        guard renderer != nil, let item else { return }
        push(item)
    }

    func start(_ item: VideoItem) {
        generation += 1
        let mine = generation
        self.item = item
        appliedScene = nil
        appliedFPS = nil
        // Loading a scene takes a moment, so it happens off the main actor.
        let path = item.url.path
        Task.detached(priority: .userInitiated) { [weak self] in
            let box: Result<RendererBox, Swift.Error>
            do {
                let renderer = try Renderer(pkgPath: path)
                box = .success(RendererBox(renderer))
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
            self.item = nil
            onFailure?(item, "Couldn’t play “\(item.name)”. \(error.localizedDescription)")
        case .success(let box):
            let renderer = box.renderer
            self.renderer = renderer
            for message in renderer.loadErrors() {
                NSLog("LiveWallpaper: \(item.name): \(message)")
            }
            for display in windows.displays() {
                let pointer = UInt64(UInt(bitPattern: Unmanaged.passUnretained(display.layer).toOpaque()))
                renderer.attachLayer(displayId: display.id, layerPtr: pointer,
                                     width: UInt32(display.pixelWidth), height: UInt32(display.pixelHeight))
                attached.append(display.id)
            }
            renderer.setMuted(muted: muted)
            if paused { renderer.pause() } else { renderer.play() }
            onReady?(item)
            push(item)
        }
    }

    func stop() {
        generation += 1
        item = nil
        appliedScene = nil
        appliedFPS = nil
        for id in attached {
            renderer?.detachLayer(displayId: id)
        }
        attached = []
        renderer?.stop()
        renderer = nil
        windows.close()
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        if paused { renderer?.pause() } else { renderer?.play() }
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        renderer?.setMuted(muted: muted)
    }

    /// The lock screen and a sleeping Mac: nothing is drawn.
    func setScreenLocked(_ locked: Bool) {
        hidden = locked
        renderer?.setVisible(visible: !locked)
    }

    /// Sends the settings that changed since the last push.
    private func push(_ item: VideoItem) {
        guard let renderer else { return }
        let new = state.sceneOptions[item.id.uuidString] ?? .standard
        let old = appliedScene
        let fps = new.fps ?? state.sceneFPS
        if new.fitMode != old?.fitMode {
            renderer.setFitMode(mode: new.fitMode.renderer)
        }
        if new.panX != old?.panX || new.panY != old?.panY || new.zoom != old?.zoom {
            // The sliders are 0...1 with 0.5 in the middle; the renderer wants the offset.
            renderer.setPanZoom(panX: Float(new.panX - 0.5), panY: Float(new.panY - 0.5), zoom: Float(new.zoom))
        }
        if new.renderScale != old?.renderScale {
            renderer.setRenderScale(scale: Float(new.renderScale))
        }
        if new.volume != old?.volume {
            renderer.setVolume(volume: Float(new.volume))
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
        appliedScene = new
        appliedFPS = fps
    }
}

private extension SceneFitMode {
    var renderer: FitMode {
        switch self {
        case .fill: return .fill
        case .fit: return .fit
        case .stretch: return .stretch
        case .none: return .unscaled
        case .matchBlurred: return .matchBlurred
        }
    }
}

private extension ScenePropertyValue {
    /// The renderer takes JSON: a number, a string or "r g b" for a colour.
    var json: String {
        switch self {
        case .bool(let v): return v ? "true" : "false"
        case .number(let v): return String(v)
        case .string(let v): return "\"\(v)\""
        case .color(let r, let g, let b): return "\"\(r) \(g) \(b)\""
        }
    }
}

private extension SceneFitMode {
    var bridge: BridgeScalingMode {
        switch self {
        case .fill: return .fill
        case .fit: return .match
        case .stretch: return .stretch
        case .none: return .none
        case .matchBlurred: return .matchBlurred
        }
    }
}

private extension BatteryMode {
    var bridge: BridgeBatteryMode {
        switch self {
        case .keepRunning: return .keepRunning
        case .reducedQuality: return .reducedQuality
        case .pause: return .pause
        }
    }
}

private extension ScenePropertyValue {
    var bridge: BridgePropertyValue {
        switch self {
        case .bool(let v): return .bool(value: v)
        case .number(let v): return .number(value: v)
        case .string(let v): return .string(value: v)
        case .color(let r, let g, let b): return .colorRgb(red: r, green: g, blue: b)
        }
    }
}
