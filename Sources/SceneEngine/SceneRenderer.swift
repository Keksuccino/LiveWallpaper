import Foundation
import CoreGraphics
import Metal
import Core
import SceneFormat

// Owner: SCENERENDER. The Metal scene renderer. It is TIME-DRIVEN: `encode(at:...)` is a function of the scene
// time you pass in, so the same code serves live playback (the host's frame pump passes a wall clock) and the
// offline lock screen render (LockVideoRenderer passes frame times). Contract and milestones: SPEC3.md section 3.4.
//
// Rules: runs only in LiveWallpaperSceneHost (the agent and Settings never link this target). No AppKit here: the
// host owns windows and layers. Textures stay compressed on the GPU (BC1/2/3). Everything is created lazily and can
// be dropped again with `releaseGPUResources()` (covered desktop, memory budget).

public struct ParallaxInput: Equatable, Sendable {
    /// Pointer position relative to the screen centre, each axis in -1...1 (y up). `.zero` = centred.
    public var x: Float
    public var y: Float

    public init(x: Float = 0, y: Float = 0) {
        self.x = x
        self.y = y
    }

    public static let zero = ParallaxInput()
}

public struct RenderOptions: Sendable {
    public var pixelWidth: Int               // size of the targets passed to encode(); the scene is fitted to it
    public var pixelHeight: Int
    public var pixelFormat: MTLPixelFormat   // of the targets (bgra8Unorm for CAMetalLayer, bgra8Unorm for offline)
    public var textureBudgetBytes: Int       // upper bound for resident textures; evicts least recently drawn above it
    public var fitMode: FitMode

    public enum FitMode: Sendable {
        case fill      // like the video player's resizeAspectFill: covers the target, crops the overflow
        case fit       // letterbox
    }

    public init(pixelWidth: Int, pixelHeight: Int, pixelFormat: MTLPixelFormat = .bgra8Unorm,
                textureBudgetBytes: Int = 400 * 1024 * 1024, fitMode: FitMode = .fill) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.pixelFormat = pixelFormat
        self.textureBudgetBytes = textureBudgetBytes
        self.fitMode = fitMode
    }
}

public enum SceneRendererError: Error, Equatable, LocalizedError {
    case notImplemented(String)
    case noGPU
    case textureFailed(String)
    case shaderFailed(String)
    case encodeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented(let what): return "Not implemented yet: \(what)."
        case .noGPU: return "No Metal GPU is available."
        case .textureFailed(let what): return "A texture could not be loaded (\(what))."
        case .shaderFailed(let what): return "The scene engine could not set up its shaders (\(what))."
        case .encodeFailed(let what): return "Drawing the scene failed (\(what))."
        }
    }
}

/// Not thread safe: create it, call it and release it on one queue (the host uses the main queue for live play and a
/// utility queue for lock renders; they use separate instances).
public final class SceneRenderer {
    public let options: RenderOptions
    public let designSize: CGSize                 // the scene's own coordinate space (e.g. 1920 x 1080)
    /// True when `encode(at:)` may be called with any time in any order (M0: yes). Stateful milestones (particles,
    /// scripts) return false; LockVideoRenderer then renders strictly in order and uses a second instance for the
    /// crossfade source.
    public private(set) var supportsRandomAccessTime: Bool = true
    /// Bytes of GPU textures currently held (for the budget and the measurements in SPEC3.md section 8).
    public private(set) var residentTextureBytes: Int = 0
    /// What this build can draw; mirrors EngineCapabilities.current.
    public static var capabilities: EngineCapabilities { .current }

    private let device: MTLDevice
    private let scene: LoadedScene?
    private let previewImage: CGImage?

    /// A scene renderer. Does not touch the GPU beyond creating the command queue; call `prepare()` to load textures.
    public init(scene: LoadedScene, device: MTLDevice, options: RenderOptions) throws {
        self.scene = scene
        self.previewImage = nil
        self.device = device
        self.options = options
        self.designSize = CGSize(width: scene.analysis.designWidth, height: scene.analysis.designHeight)
    }

    /// A renderer that shows one still image (previewOnly scenes, and scenes that failed to load), scaled per
    /// `options.fitMode`.
    public init(previewImage: CGImage, device: MTLDevice, options: RenderOptions) throws {
        self.scene = nil
        self.previewImage = previewImage
        self.device = device
        self.options = options
        self.designSize = CGSize(width: previewImage.width, height: previewImage.height)
    }

    /// Compiles pipelines and loads the textures of visible layers. Safe to call again after
    /// `releaseGPUResources()`. Throws .textureFailed / .shaderFailed; the host then falls back to the preview image.
    public func prepare() throws {
        throw SceneRendererError.notImplemented("SceneRenderer.prepare")
    }

    /// Encodes one frame of the scene at `time` (seconds on the scene clock, >= 0) into `target` using
    /// `commandBuffer`. Does not commit or wait: the caller owns the command buffer (live: present the drawable then
    /// commit; offline: commit and wait). `target` has `options.pixelWidth x pixelHeight` and `options.pixelFormat`
    /// and `.renderTarget` usage.
    public func encode(at time: Double, parallax: ParallaxInput, into target: MTLTexture,
                       commandBuffer: MTLCommandBuffer) throws {
        throw SceneRendererError.notImplemented("SceneRenderer.encode")
    }

    /// Drops textures and pipelines (keeps the parsed document). `prepare()` brings them back.
    public func releaseGPUResources() {
        residentTextureBytes = 0
    }
}
