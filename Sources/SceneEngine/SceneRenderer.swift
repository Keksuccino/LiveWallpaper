import Foundation
import CoreGraphics
import Metal
import simd

import Core
import SceneFormat

// Owner: SCENERENDER. The Metal scene renderer. It is TIME-DRIVEN: `encode(at:...)` is a function of the scene
// time you pass in, so the same code serves live playback (the host's frame pump passes a wall clock) and the
// offline lock screen render (LockVideoRenderer passes frame times). Contract and milestones: SPEC3.md section 3.4.
//
// Rules: runs only in LiveWallpaperSceneHost (the agent and Settings never link this target). No AppKit here: the
// host owns windows and layers. Textures stay compressed on the GPU (BC1/2/3). Everything is created lazily and can
// be dropped again with `releaseGPUResources()` (covered desktop, memory budget). In M0 a scene is stateless
// (parallax only), so `encode(at:)` is a pure function of the input; particles/scripts (M1+) will make
// `supportsRandomAccessTime` false.

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
    public var pixelFormat: MTLPixelFormat   // of the targets (bgra8Unorm for CAMetalLayer and offline)
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
    public let designSize: CGSize
    /// True when `encode(at:)` may be called with any time in any order (M0: yes).
    public private(set) var supportsRandomAccessTime: Bool = true
    /// Bytes of GPU textures currently held (budget and measurements, SPEC3.md section 8).
    public private(set) var residentTextureBytes: Int = 0
    /// Radius factor K of the parallax movement in scene units at pointer extremes (SPEC3.md section 5.3):
    /// offset = -p * parallaxAmount * mouseInfluence * parallaxDepth * (parallaxScale * designWidth).
    /// Tunable in one place (T10 compares against Wallpaper Engine on a real Mac).
    public static let parallaxScale: Double = 0.02

    /// What this build can draw; mirrors EngineCapabilities.current.
    public static var capabilities: EngineCapabilities { .current }

    static let identity4 = simd_float4x4(columns: (
        simd_float4(1, 0, 0, 0), simd_float4(0, 1, 0, 0), simd_float4(0, 0, 1, 0), simd_float4(0, 0, 0, 1)))

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let scene: LoadedScene?
    private let previewImage: CGImage?
    private let textureCache: SceneTextureCache
    private var layers: [PreparedLayer] = []

    private var library: MTLLibrary?
    private struct PipelineKey: Hashable { var blend: BlendMode; var format: MTLPixelFormat }
    private var pipelines: [PipelineKey: MTLRenderPipelineState] = [:]
    private var crossfadePipeline: MTLRenderPipelineState?

    private struct SamplerKey: Hashable { var nearest: Bool }
    private var samplers: [SamplerKey: MTLSamplerState] = [:]

    private struct ProjectionKey: Hashable { var width: Int; var height: Int }
    private var projections: [ProjectionKey: simd_float4x4] = [:]

    private var prepared = false

    // MARK: construction

    /// A scene renderer. Does not touch the GPU beyond creating the command queue; call `prepare()` to load textures.
    public init(scene: LoadedScene, device: MTLDevice, options: RenderOptions) throws {
        self.scene = scene
        self.previewImage = nil
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw SceneRendererError.noGPU }
        self.queue = queue
        self.options = options
        self.textureCache = SceneTextureCache(budgetBytes: options.textureBudgetBytes)
        self.designSize = CGSize(width: scene.analysis.designWidth, height: scene.analysis.designHeight)
        self.layers = Self.flatten(scene: scene, files: scene.files)
    }

    /// A renderer that shows one still image (previewOnly scenes, and scenes that failed to load), scaled per
    /// `options.fitMode`. `encode(at:)` draws it for every time and parallax value.
    public init(previewImage: CGImage, device: MTLDevice, options: RenderOptions) throws {
        self.scene = nil
        self.previewImage = previewImage
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw SceneRendererError.noGPU }
        self.queue = queue
        self.options = options
        self.textureCache = SceneTextureCache(budgetBytes: options.textureBudgetBytes)
        self.designSize = CGSize(width: max(1, previewImage.width), height: max(1, previewImage.height))
    }

    // MARK: GPU setup

    /// Compiles pipelines and loads the textures of visible layers. Safe to call again after
    /// `releaseGPUResources()`. Throws .textureFailed / .shaderFailed; the host then falls back to the preview image.
    public func prepare() throws {
        releaseGPUResources()
        try makeLibraryAndPipelines()

        if let scene {
            var loadedAny = false
            for index in layers.indices {
                guard let content = layers[index].content else { continue }
                let texture = textureCache.texture(for: layers[index].path!, content: content, device: device)
                layers[index].resolvedTexture = texture
                if let texture, texture.pixelFormat == .r8Unorm { layers[index].singleChannel = true }
                if texture != nil { loadedAny = true }
            }
            residentTextureBytes = textureCache.residentBytes
            guard loadedAny else {
                throw SceneRendererError.textureFailed("no layer of the scene could be loaded")
            }
        } else {
            guard let image = previewImage else { throw SceneRendererError.textureFailed("no preview") }
            guard textureCache.texture(image: image, device: device) != nil else {
                throw SceneRendererError.textureFailed("the preview image could not be uploaded")
            }
            residentTextureBytes = textureCache.residentBytes
        }
        prepared = true
    }

    /// Drops textures and pipelines (keeps the parsed document). `prepare()` brings them back.
    public func releaseGPUResources() {
        textureCache.removeAll()
        pipelines = [:]
        library = nil
        crossfadePipeline = nil
        samplers = [:]
        projections = [:]
        for index in layers.indices { layers[index].resolvedTexture = nil }
        residentTextureBytes = 0
        prepared = false
    }

    // MARK: drawing

    /// Encodes one frame of the scene at `time` (seconds on the scene clock, >= 0) into `target` using
    /// `commandBuffer`. Does not commit or wait: the caller owns the command buffer (live: present the drawable then
    /// commit; offline: commit and wait). `target` has `options.pixelWidth x pixelHeight` and `options.pixelFormat`
    /// and `.renderTarget` usage. M0: parallax changes the output, `time` does not (a parallax-only scene is static).
    public func encode(at time: Double, parallax: ParallaxInput, into target: MTLTexture,
                       commandBuffer: MTLCommandBuffer) throws {
        guard prepared, library != nil, !pipelines.isEmpty else {
            throw SceneRendererError.encodeFailed("prepare() has not succeeded")
        }
        if scene != nil, time < 0 {
            throw SceneRendererError.encodeFailed("time must be >= 0")
        }

        let clearColor: Vec3 = scene?.document.general.clearColor ?? Vec3(0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.passDescriptor(
            target: target, red: Double(clearColor.x), green: Double(clearColor.y), blue: Double(clearColor.z)))
        else { throw SceneRendererError.encodeFailed("no render encoder") }
        defer { encoder.endEncoding() }

        let projection = projection(for: target)
        if let scene {
            for layer in layers {
                guard let texture = layer.resolvedTexture else { continue }
                let blend: BlendMode = Self.capabilities.blendModes.contains(layer.blend) ? layer.blend : .normal
                let uniform = uniform(for: layer, projection: projection, parallax: parallax)
                draw(encoder: encoder, blend: blend, uniform: uniform, texture: texture,
                     mix: 0, singleChannel: layer.singleChannel)
            }
        } else {
            let uniform = previewUniforms(target: target)
            guard let image = previewImage, let texture = textureCache.texture(image: image, device: device) else {
                throw SceneRendererError.encodeFailed("the preview texture is gone")
            }
            draw(encoder: encoder, blend: .opaque, uniform: uniform, texture: texture,
                 mix: 0, singleChannel: false)
        }
    }

    /// Internal (SPEC3.md section 1.5 step 6): blends two already rendered loop sources with weight `mix`
    /// (0 = primary only, 1 = secondary only). Caller renders both sources first and owns the buffer.
    func encodeCrossfade(primary: MTLTexture, secondary: MTLTexture, mix: Float, into target: MTLTexture,
                         commandBuffer: MTLCommandBuffer) throws {
        guard prepared, let pipeline = crossfadePipeline else {
            throw SceneRendererError.encodeFailed("prepare() has not succeeded")
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: Self.passDescriptor(
            target: target, red: 0, green: 0, blue: 0)) else {
            throw SceneRendererError.encodeFailed("no render encoder")
        }
        defer { encoder.endEncoding() }

        var uniform = SceneShaderSource.LayerUniforms(
            model: Self.identity4,
            projection: Self.identity4,     // the quad IS the target: local -1..1 -> ndc -1..1
            tint: simd_float4(1, 1, 1, 1),
            uvs: simd_float4(0, 0, 1, 1))
        var glob = SceneShaderSource.GlobalUniforms(crossfadeMix: mix, singleChannel: 0)
        encoder.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &uniform) {
            encoder.setVertexBytes($0.baseAddress!, length: MemoryLayout<SceneShaderSource.LayerUniforms>.stride,
                                   index: 0)
        }
        encoder.setFragmentTexture(primary, index: 0)
        encoder.setFragmentTexture(secondary, index: 1)
        encoder.setFragmentSamplerState(sampler(nearest: false), index: 0)
        withUnsafeBytes(of: &uniform) {
            encoder.setFragmentBytes($0.baseAddress!, length: MemoryLayout<SceneShaderSource.LayerUniforms>.stride,
                                     index: 1)
        }
        withUnsafeBytes(of: &glob) {
            encoder.setFragmentBytes($0.baseAddress!, length: MemoryLayout<SceneShaderSource.GlobalUniforms>.stride,
                                     index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    // MARK: internals (drawing)

    private static func passDescriptor(target: MTLTexture, red: Double, green: Double, blue: Double)
        -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: red, green: green, blue: blue, alpha: 1)
        return pass
    }

    private func draw(encoder: MTLRenderCommandEncoder, blend: BlendMode,
                      uniform: SceneShaderSource.LayerUniforms, texture: MTLTexture,
                      mix: Float, singleChannel: Bool) {
        var uniform = uniform
        var glob = SceneShaderSource.GlobalUniforms(crossfadeMix: mix, singleChannel: singleChannel ? 1 : 0)
        encoder.setRenderPipelineState(pipeline(for: blend, format: options.pixelFormat))
        withUnsafeBytes(of: &uniform) {
            encoder.setVertexBytes($0.baseAddress!, length: MemoryLayout<SceneShaderSource.LayerUniforms>.stride,
                                   index: 0)
        }
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler(nearest: false), index: 0)
        withUnsafeBytes(of: &uniform) {
            encoder.setFragmentBytes($0.baseAddress!, length: MemoryLayout<SceneShaderSource.LayerUniforms>.stride,
                                     index: 1)
        }
        withUnsafeBytes(of: &glob) {
            encoder.setFragmentBytes($0.baseAddress!, length: MemoryLayout<SceneShaderSource.GlobalUniforms>.stride,
                                     index: 2)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    // MARK: internals (shaders, samplers)

    private func makeLibraryAndPipelines() throws {
        if library == nil {
            do { library = try device.makeLibrary(source: SceneShaderSource.m0, options: nil) }
            catch { throw SceneRendererError.shaderFailed("\(error)") }
        }
        guard let library else { throw SceneRendererError.shaderFailed("no library") }
        for blend in [BlendMode.normal, .opaque, .additive, .multiply, .screen] {
            pipelines[PipelineKey(blend: blend, format: options.pixelFormat)]
                = try makePipeline(library: library, blend: blend, format: options.pixelFormat)
        }
        if crossfadePipeline == nil {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "scene_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "crossfade_fragment")
            descriptor.colorAttachments[0].pixelFormat = options.pixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do { crossfadePipeline = try device.makeRenderPipelineState(descriptor: descriptor) }
            catch { throw SceneRendererError.shaderFailed("\(error)") }
        }
    }

    private func makePipeline(library: MTLLibrary, blend: BlendMode, format: MTLPixelFormat) throws
        -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "scene_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "scene_fragment")
        descriptor.colorAttachments[0].pixelFormat = format
        descriptor.colorAttachments[0].isBlendingEnabled = blend != .opaque
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        switch blend {
        case .normal, .unknown:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        case .opaque:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
        case .additive:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        case .multiply:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
        case .screen:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .oneMinusDestinationColor
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
        }
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do { return try device.makeRenderPipelineState(descriptor: descriptor) }
        catch { throw SceneRendererError.shaderFailed("\(error)") }
    }

    private func pipeline(for blend: BlendMode, format: MTLPixelFormat) -> MTLRenderPipelineState {
        pipelines[PipelineKey(blend: blend, format: format)] ?? pipelines[PipelineKey(blend: .normal, format: format)]!
    }

    private func sampler(nearest: Bool) -> MTLSamplerState {
        let key = SamplerKey(nearest: nearest)
        if let existing = samplers[key] { return existing }
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = nearest ? .nearest : .linear
        descriptor.magFilter = nearest ? .nearest : .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.rAddressMode = .clampToEdge
        let state = device.makeSamplerState(descriptor: descriptor)
        samplers[key] = state
        return state ?? device.makeSamplerState(descriptor: MTLSamplerDescriptor())!
    }

    // MARK: internals (transforms and uniforms)

    private func previewImageValue() -> CGImage? { previewImage }

    private func uniform(for layer: PreparedLayer, projection: simd_float4x4, parallax: ParallaxInput)
        -> SceneShaderSource.LayerUniforms {
        var tilted = projection
        if parallax != .zero, layer.parallaxDepth != .zero {
            // offset = -p * amount * influence * depth * K, in scene units (SPEC3.md section 5.3).
            let amount = scene?.document.general.parallaxAmount ?? 1
            let influence = scene?.document.general.parallaxMouseInfluence ?? 1
            let k = Float(Self.parallaxScale * max(1, designSize.width))
            let dx = -parallax.x * Float(amount * influence) * Float(layer.parallaxDepth.x) * k
            let dy = -parallax.y * Float(amount * influence) * Float(layer.parallaxDepth.y) * k
            tilted = tilted * simd_float4x4(columns: (
                simd_float4(1, 0, 0, 0), simd_float4(0, 1, 0, 0), simd_float4(0, 0, 1, 0),
                simd_float4(dx, dy, 0, 1)))
        }
        return SceneShaderSource.LayerUniforms(model: layer.model, projection: tilted, tint: layer.tint,
                                               uvs: layer.uvs)
    }

    private func previewUniforms(target: MTLTexture) -> SceneShaderSource.LayerUniforms {
        // The still spans its own design size (its pixels), 0..width x 0..height in world space (the projection's
        // camera centre is designSize/2 for a preview); local -1..1 covers exactly that.
        let halfWidth = Float(max(1, designSize.width) / 2), halfHeight = Float(max(1, designSize.height) / 2)
        let model = simd_float4x4(columns: (
            simd_float4(halfWidth, 0, 0, 0), simd_float4(0, halfHeight, 0, 0),
            simd_float4(0, 0, 1, 0), simd_float4(halfWidth, halfHeight, 0, 1)))
        return SceneShaderSource.LayerUniforms(model: model, projection: projection(for: target),
                                               tint: simd_float4(1, 1, 1, 1), uvs: simd_float4(0, 0, 1, 1))
    }

    private func projection(for target: MTLTexture) -> simd_float4x4 {
        let key = ProjectionKey(width: target.width, height: target.height)
        if let cached = projections[key] { return cached }
        let scale = Float(fitScale(targetWidth: target.width, targetHeight: target.height))
        let sx = 2 * scale / Float(target.width), sy = 2 * scale / Float(target.height)
        let camera = scene?.document.camera.center ?? Vec3(designSize.width / 2, designSize.height / 2, 0)
        let value = simd_float4x4(columns: (
            simd_float4(sx, 0, 0, 0), simd_float4(0, sy, 0, 0), simd_float4(0, 0, 1, 0),
            simd_float4(-sx * Float(camera.x), -sy * Float(camera.y), 0, 1)))
        projections[key] = value
        return value
    }

    /// Scene units -> pixels per unit. `.fill` covers the target (like resizeAspectFill), `.fit` letterboxes.
    private func fitScale(targetWidth: Int, targetHeight: Int) -> Double {
        let designW = max(1, designSize.width), designH = max(1, designSize.height)
        switch options.fitMode {
        case .fill: return max(Double(targetWidth) / designW, Double(targetHeight) / designH)
        case .fit: return min(Double(targetWidth) / designW, Double(targetHeight) / designH)
        }
    }

    // MARK: flattening (CPU, fixed for the lifetime of the renderer)

    struct PreparedLayer {
        var path: String?
        var content: Data?
        var blend: BlendMode
        var uvs: simd_float4                 // u0, v0, du, dv: the picture inside the stored texture
        var singleChannel: Bool
        var model: simd_float4x4             // parents composed; local quad space is -1..1
        var parallaxDepth: Vec2
        var tint: simd_float4
        var resolvedTexture: MTLTexture?
    }

    /// Flattens the document into draw-ordered quads. Pure CPU matrix algebra plus texture headers (no pixels).
    /// Draw order is the file order (back to front); invisible/zero-alpha layers and children of hidden parents
    /// are skipped entirely.
    static func flatten(scene: LoadedScene, files: SceneFileSource) -> [PreparedLayer] {
        let designWidth = scene.document.general.designWidth
        var layers: [PreparedLayer] = []
        var localByID: [Int: simd_float4x4] = [:]
        var visibleByID: [Int: Bool] = [:]

        for object in scene.document.objects {
            let localBase = localMatrix(for: object)
            localByID[object.id] = localBase
            visibleByID[object.id] = object.visible

            guard object.visible else { continue }
            var chain = Self.identity4
            var hiddenAncestor = false
            var cursor = object.parentID
            var depth = 0
            while let id = cursor, let ancestorLocal = localByID[id], depth < 32 {
                chain = ancestorLocal * chain
                hiddenAncestor = hiddenAncestor || (visibleByID[id] == false)
                cursor = nil
                for other in scene.document.objects where other.id == id { cursor = other.parentID }
                depth += 1
            }
            if hiddenAncestor { continue }

            guard case .image(let layer) = object.kind else { continue }

            let radians = Float(object.angles.z * .pi / 180)
            let rotation = simd_float4x4(columns: (
                simd_float4(cos(radians), sin(radians), 0, 0), simd_float4(-sin(radians), cos(radians), 0, 0),
                simd_float4(0, 0, 1, 0), simd_float4(0, 0, 0, 1)))
            var halfW = Float(object.scale.x), halfH = Float(object.scale.y)
            if let size = object.size ?? layer.sourceSize {
                halfW = Float(size.x * object.scale.x / 2)
                halfH = Float(size.y * object.scale.y / 2)
            } else if let content = try? files.data(at: layer.texturePath ?? ""),
                      let header = try? TexDecoder.header(for: content) {
                halfW = Float(Double(header.imageWidth) * object.scale.x / 2)
                halfH = Float(Double(header.imageHeight) * object.scale.y / 2)
            } else {
                halfW = Float(min(designWidth, Double(scene.analysis.designWidth)) / 2)   // broken size: harmless placeholder
                halfH = halfW
            }
            let halfScale = simd_float4x4(columns: (
                simd_float4(max(1, halfW), 0, 0, 0), simd_float4(0, max(1, halfH), 0, 0),
                simd_float4(0, 0, 1, 0), simd_float4(0, 0, 0, 1)))
            let local = localBase

            var prepared = PreparedLayer(
                path: layer.texturePath, content: content(of: layer, files: files), blend: layer.blend,
                uvs: simd_float4(0, 0, 1, 1), singleChannel: false, model: chain * local * halfScale,
                parallaxDepth: object.parallaxDepth,
                tint: simd_float4(Float(object.color.x * object.brightness),
                                  Float(object.color.y * object.brightness),
                                  Float(min(1, object.color.z * object.brightness)),
                                  Float(min(1, max(0, object.alpha)))),
                resolvedTexture: nil)

            // UV window: the picture occupies the top-left imageWidth x imageHeight of the padded texture
            // (UNVERIFIED, T10). For a sprite sheet, frame 0 covers the picture like a normal image (M0).
            if let content = prepared.content, let header = try? TexDecoder.header(for: content),
               header.textureWidth > 0, header.textureHeight > 0 {
                let du = Float(header.imageWidth) / Float(header.textureWidth)
                let dv = Float(header.imageHeight) / Float(header.textureHeight)
                prepared.uvs = simd_float4(0, 0, max(0.0001, du), max(0.0001, dv))
            }
            layers.append(prepared)
        }
        return layers
    }

    private static func content(of layer: ImageLayer, files: SceneFileSource) -> Data? {
        guard let path = layer.texturePath else { return nil }
        return try? files.data(at: path)
    }

    /// Local transform of one object: T(origin) * Rz(angles.z) * S(scale). Scene units, y up, origin bottom-left
    /// (the parser already mirrored the file's y-down coordinates; UNVERIFIED, see T10).
    private static func localMatrix(for object: SceneObject) -> simd_float4x4 {
        let radians = Float(object.angles.z * .pi / 180)
        let rotation = simd_float4x4(columns: (
            simd_float4(cos(radians), sin(radians), 0, 0), simd_float4(-sin(radians), cos(radians), 0, 0),
            simd_float4(0, 0, 1, 0), simd_float4(0, 0, 0, 1)))
        let scale = simd_float4x4(columns: (
            simd_float4(Float(object.scale.x), 0, 0, 0), simd_float4(0, Float(object.scale.y), 0, 0),
            simd_float4(0, 0, 1, 0), simd_float4(0, 0, 0, 1)))
        let translate = simd_float4x4(columns: (
            simd_float4(1, 0, 0, 0), simd_float4(0, 1, 0, 0), simd_float4(0, 0, 1, 0),
            simd_float4(Float(object.origin.x), Float(object.origin.y), 0, 1)))
        return translate * rotation * scale
    }
}
