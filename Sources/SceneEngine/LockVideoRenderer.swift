import Foundation
import CoreGraphics
import ImageIO
import Metal
import AVFoundation
import Core
import SceneFormat

// Owner: SCENERENDER. The offline lock screen render: drives a SceneRenderer frame by frame (no display link, no
// window), blends the loop seam with LoopPlan, and writes an HEVC .mov with AVAssetWriter. Runs inside the scene
// host at low priority. Contract: SPEC3.md sections 1.5 and 3.4.

public struct LockRenderRequest: Sendable {
    public var scenePath: URL                 // VideoItem.path (scene.pkg or scene.json); ignored when scenePath is a still
    public var previewPath: URL?              // used for previewOnly scenes: encoded as a static loop
    public var assetsPath: URL?               // shared assets folder if present
    public var outputURL: URL                 // the final .mov; the writer first writes <name>.partial.mov next to it
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fps: Int
    public var loopSeconds: Double?           // nil = LoopPlan.choose(scenePeriod:)

    public init(scenePath: URL, previewPath: URL? = nil, assetsPath: URL? = nil, outputURL: URL,
                pixelWidth: Int, pixelHeight: Int, fps: Int = 30, loopSeconds: Double? = nil) {
        self.scenePath = scenePath
        self.previewPath = previewPath
        self.assetsPath = assetsPath
        self.outputURL = outputURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.loopSeconds = loopSeconds
    }
}

public enum LockRenderError: Error, Equatable, LocalizedError {
    case notImplemented
    case cancelled
    case sceneUnreadable(String)
    case noGPU
    case writerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented: return "The lock screen renderer is not implemented yet."
        case .cancelled: return "Rendering was cancelled."
        case .sceneUnreadable(let why): return "The scene could not be read (\(why))."
        case .noGPU: return "No Metal GPU is available."
        case .writerFailed(let why): return "The video could not be written (\(why))."
        }
    }
}

public enum LockVideoRenderer {
    /// Renders the loop and returns the loop length in seconds on success. Progress is 0...1 and is reported at least
    /// every 0.5 s of wall time. `isCancelled` is polled between frames; on cancel the partial file is deleted and
    /// `LockRenderError.cancelled` is thrown. On success the file at `outputURL` is complete (partial file renamed);
    /// writing the cache metadata (LockRenderCache.writeMeta) is the caller's job. Uses SceneRenderer at pixel size
    /// request.pixelWidth x pixelHeight, `.fill` fit, parallax `.zero` (a lock screen has no pointer), and no audio.
    public static func render(_ request: LockRenderRequest,
                              progress: @escaping @Sendable (Double) -> Void,
                              isCancelled: @escaping @Sendable () -> Bool) async throws -> Double {
        let width = max(2, request.pixelWidth - (request.pixelWidth % 2))
        let height = max(2, request.pixelHeight - (request.pixelHeight % 2))
        // Lock screen shows a still for now: a few identical frames of the scene at t = 0, no loop seam.
        let fps = 1

        // Scene or preview fallback: every failure path shows the preview image (never a black lock screen).
        var loaded: LoadedScene?
        var loadError: String?
        do {
            if request.scenePath.pathExtension.lowercased() == "pkg" {
                loaded = try SceneLoader.load(packageAt: request.scenePath, sharedAssets: request.assetsPath)
            } else {
                loaded = try SceneLoader.load(directory: request.scenePath, sharedAssets: request.assetsPath)
            }
        } catch {
            loadError = error.localizedDescription
        }

        let preview = makePreviewImage(request.previewPath, fallback: loadError)
        let device = MetalDevice.shared
        let plan = LoopPlan(loopSeconds: 4, crossfadeSeconds: 0, fps: fps)

        let renderer: SceneRenderer
        do {
            let options = RenderOptions(pixelWidth: width, pixelHeight: height, pixelFormat: .bgra8Unorm,
                                        textureBudgetBytes: 400 * 1024 * 1024, fitMode: .fill)
            if let loaded, loaded.analysis.support != .previewOnly,
               let device {
                let sceneRenderer = try SceneRenderer(scene: loaded, device: device, options: options)
                try sceneRenderer.prepare()
                renderer = sceneRenderer
            } else if let preview, let device {
                let still = try SceneRenderer(previewImage: preview, device: device, options: options)
                try still.prepare()
                renderer = still
            } else {
                throw LockRenderError.noGPU
            }
        } catch {
            // The scene could not be rendered: fall back to the preview image with the same pipeline.
            if let preview, let device {
                do {
                    let options = RenderOptions(pixelWidth: width, pixelHeight: height, pixelFormat: .bgra8Unorm,
                                                textureBudgetBytes: 64 * 1024 * 1024, fitMode: .fill)
                    let still = try SceneRenderer(previewImage: preview, device: device, options: options)
                    try still.prepare()
                    renderer = still
                } catch {
                    throw LockRenderError.sceneUnreadable(loadError ?? "\(error)")
                }
            } else {
                throw LockRenderError.sceneUnreadable(loadError ?? "\(error)")
            }
        }
        defer { renderer.releaseGPUResources() }

        // Targets: the frame input, optionally the crossfade source, and the crossing output when the loop needs
        // a seam blend (a texture cannot be read and written in the same draw).
        let target = try offscreenTarget(width: width, height: height, device: device)
        let secondary = plan.crossfadeFrames > 0 ? try offscreenTarget(width: width, height: height, device: device)
                                                 : target
        let outputTarget = plan.crossfadeFrames > 0 ? try offscreenTarget(width: width, height: height, device: device)
                                                    : target

        // The writer lands next to the final output: "<name>.partial.<ext>".
        let partialURL = partialURL(for: request.outputURL)
        try? FileManager.default.removeItem(at: partialURL)

        let made = try makeWriter(width: width, height: height, fps: fps, outputURL: partialURL)
        let writer = made.writer
        let input = made.input
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        defer { if writer.status != .completed { try? FileManager.default.removeItem(at: partialURL) } }

        let totalCalls = plan.renderCalls
        var lastProgress = Date.distantPast

        for callIndex in 0..<totalCalls {
            if isCancelled() { throw LockVideoRenderer.cancelWrite(writer, partialURL: partialURL) }
            let source = plan.source(forFrame: callIndex)
            var frameTarget = target
            try renderSource(renderer, time: source.primary, into: target, device: device)
            if let secondaryTime = source.secondary {
                try renderSource(renderer, time: secondaryTime, into: secondary, device: device)
                // out = (1 - a) f(t) + a f(t+T)? No (LoopPlan): out = (1-a) f(t+T) + a f(t), a = i/crossfadeFrames,
                // mix = 1 - a; the fragment computes texA*(1-w) + texB*w, so texA = f(t), texB = f(t+T).
                try renderer.encodeCrossfade(primary: target, secondary: secondary, mix: source.mix,
                                             into: outputTarget, commandBuffer: try buffer(device))
                frameTarget = outputTarget
            }

            // The pixel buffer pool owns frame memory; append when the input takes data.
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw LockRenderError.writerFailed(writer.error?.localizedDescription ?? "writer failed")
                }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            var pixelBufferMaybe: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferMaybe) == kCVReturnSuccess,
                  let pixelBuffer = pixelBufferMaybe else {
                throw LockRenderError.writerFailed("no free pixel buffer")
            }
            copyTexture(frameTarget, into: pixelBuffer)
            if !adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(callIndex),
                                                                        timescale: CMTimeScale(fps))) {
                let why = writer.error?.localizedDescription ?? "a frame could not be appended"
                throw LockRenderError.writerFailed(why)
            }

            let now = Date()
            if now.timeIntervalSince(lastProgress) >= 0.5 {
                lastProgress = now
                progress(Double(callIndex + 1) / Double(totalCalls))
            }
        }
        adaptor.assetWriterInput.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw LockRenderError.writerFailed(writer.error?.localizedDescription ?? "unknown writer failure")
        }
        guard FileManager.default.fileExists(atPath: partialURL.path) else {
            throw LockRenderError.writerFailed("the partial file vanished")
        }
        try? FileManager.default.removeItem(at: request.outputURL)   // a stale render would make the move fail
        try FileManager.default.moveItem(at: partialURL, to: request.outputURL)
        progress(1)
        return plan.loopSeconds
    }

    // MARK: pieces

    /// Stops the writer, deletes the partial file and rethrows `.cancelled`.
    private static func cancelWrite(_ writer: AVAssetWriter, partialURL: URL) -> LockRenderError {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: partialURL)
        return .cancelled
    }

    private static func partialURL(for output: URL) -> URL {
        let stem = output.deletingPathExtension().lastPathComponent
        return output.deletingLastPathComponent().appendingPathComponent("\(stem).partial.\(output.pathExtension)")
    }

    private static func makeWriter(width: Int, height: Int, fps: Int, outputURL: URL) throws
        -> (writer: AVAssetWriter, input: AVAssetWriterInput) {
        let writer: AVAssetWriter?
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        } catch {
            throw LockRenderError.writerFailed("\(error)")
        }
        guard let writer else { throw LockRenderError.writerFailed("no writer") }

        let bitsPerPixelPerFrame = 0.07
        let raw = Double(width) * Double(height) * Double(fps) * bitsPerPixelPerFrame
        let bitrate = Int32(min(raw, 40_000_000))
        let settings: [String: Any]
        // HEVC when this writer can use it, H.264 fallback otherwise (spec 3.4 videoType hevc/h264).
        let hevc: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoColorPropertiesKey: [
                    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
                ],
            ],
        ]
        if writer.canApply(outputSettings: hevc, forMediaType: .video) {
            settings = hevc
        } else {
            settings = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitrate],
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        return (writer, input)
    }

    private static func buffer(_ device: MTLDevice?) throws -> MTLCommandBuffer {
        guard let device, let buffer = device.makeCommandQueue()?.makeCommandBuffer() else {
            throw LockRenderError.noGPU
        }
        return buffer
    }

    private static func renderSource(_ renderer: SceneRenderer, time: Double, into target: MTLTexture,
                                     device: MTLDevice?) throws {
        guard let device else { throw LockRenderError.noGPU }
        guard let buffer = device.makeCommandQueue()?.makeCommandBuffer() else { throw LockRenderError.noGPU }
        try renderer.encode(at: time, parallax: .zero, into: target, commandBuffer: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        if let error = buffer.error { throw LockRenderError.writerFailed(error.localizedDescription) }
    }

    private static func offscreenTarget(width: Int, height: Int, device: MTLDevice?) throws -> MTLTexture {
        guard let device else { throw LockRenderError.noGPU }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw LockRenderError.noGPU }
        return texture
    }

    /// BGRA rows from a `.shared` texture into the pixel buffer (same colour space, straight copy).
    private static func copyTexture(_ texture: MTLTexture, into pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        texture.getBytes(base, bytesPerRow: stride,
                         from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
    }

    /// The preview image as a CGImage (nil when nothing usable was given; the caller then needs a readable scene).
    private static func makePreviewImage(_ path: URL?, fallback: String?) -> CGImage? {
        guard let path else { return nil }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(path as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { return nil }
        return image
    }
}

/// One shared GPU device for the host process (the live player and the lock renderer must not fight over two).
final class MetalDevice {
    static let shared: MTLDevice? = MTLCreateSystemDefaultDevice()
}
