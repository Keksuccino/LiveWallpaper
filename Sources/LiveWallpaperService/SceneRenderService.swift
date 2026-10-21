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

    override func start(_ item: VideoItem) {
        super.start(item)
        generation += 1
        let mine = generation
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
                for display in displays {
                    _ = try await bridge.setTargetFps(wallpaperId: id, displayId: display, fps: UInt32(self.options.fps))
                }
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

    override func apply(_ options: RenderOptions) {
        let changed = options.fps != self.options.fps
        super.apply(options)
        guard changed, let id = wallpaperID, !displayIDs.isEmpty else { return }
        let displays = displayIDs
        Task { @MainActor in
            guard let bridge = try? SceneBridge.shared() else { return }
            for display in displays {
                _ = try? await bridge.setTargetFps(wallpaperId: id, displayId: display, fps: UInt32(options.fps))
            }
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
