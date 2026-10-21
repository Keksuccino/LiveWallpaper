import AppKit
import Core
import RenderBridge

/// One Rust renderer for this process (WallpaperMachine's core, see docs/render-bridge-notes.md).
/// Created on first use, after the environment it reads is set.
@MainActor enum SceneBridge {
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
        // MoltenVK for the Vulkan scene path. Homebrew's install here; a shipped app bundles its own (build.sh).
        let icd = "/opt/homebrew/etc/vulkan/icd.d/MoltenVK_icd.json"
        if getenv("VK_ICD_FILENAMES") == nil, FileManager.default.fileExists(atPath: icd) {
            setenv("VK_ICD_FILENAMES", icd, 1)
        }
    }
}

/// Scenes on the desktop, drawn by the Rust renderer. One scene at a time; all displays show it.
@MainActor final class SceneRenderService: WallpaperService {
    static let notConnected = "Scene renderer not connected yet."

    /// Library folder name of the scene (`Library/<id>/project.json`).
    private var wallpaperID: String?
    private var displayIDs: [String] = []
    private var muted = true
    private var generation = 0
    private var state = LibraryState()
    // What the renderer has been given so far; nil = nothing yet, so everything is pushed.
    private var appliedScene: SceneOptions?
    private var appliedPower: PowerOptions?
    private var appliedFPS: Int?
    private var pushChain: Task<Void, Never>?

    /// The Orchestrator's state changed (or a scene is about to start): push only what differs to the running scene.
    func update(_ state: LibraryState) {
        self.state = state
        guard let id = wallpaperID, !displayIDs.isEmpty, item != nil else { return }
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
            guard let bridge = try? SceneBridge.shared() else { return }
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

    override func start(_ item: VideoItem) {
        super.start(item)
        generation += 1
        let mine = generation
        appliedScene = nil; appliedPower = nil; appliedFPS = nil
        let id = item.url.deletingLastPathComponent().lastPathComponent
        wallpaperID = id
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let bridge = try SceneBridge.shared()
                try await SceneBridge.bootstrapIfNeeded(bridge)
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

    override func stop() {
        generation += 1
        let id = wallpaperID
        let displays = displayIDs
        wallpaperID = nil
        displayIDs = []
        appliedScene = nil; appliedPower = nil; appliedFPS = nil
        super.stop()
        guard let id else { return }
        Task { @MainActor in
            guard let bridge = try? SceneBridge.shared() else { return }
            for display in displays {
                _ = try? await bridge.ejectWallpaperFromDisplay(displayId: display, wallpaperId: id)
            }
        }
    }

    override func setPaused(_ paused: Bool) {
        // The renderer pauses every display at once; the Orchestrator's pause is global too.
        Task { @MainActor in
            guard let bridge = try? SceneBridge.shared() else { return }
            if paused { _ = try? await bridge.pauseAll() } else { _ = try? await bridge.playAll() }
        }
    }

    override func setMuted(_ muted: Bool) {
        self.muted = muted
        guard let id = wallpaperID else { return }
        Task { @MainActor in
            guard let bridge = try? SceneBridge.shared() else { return }
            _ = try? await bridge.setMuted(wallpaperId: id, muted: muted)
        }
    }

    private func failed(_ generation: Int, _ item: VideoItem, _ message: String) {
        guard generation == self.generation else { return }
        super.stop()
        wallpaperID = nil
        displayIDs = []
        onFailure?(item, message)
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
