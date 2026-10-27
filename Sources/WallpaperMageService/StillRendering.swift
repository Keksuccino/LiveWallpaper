import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Core
import SceneBridge

// Draws stills of wallpapers, off the main actor: a scene through an off-screen Renderer of its own, a video's frame
// through the colour options and placed like the player places it. WallpaperStills makes each display's system
// wallpaper with it, LibraryPreviews the library's previews.

/// The pixels a still is drawn into.
struct StillCanvas: Sendable {
    let width: Int
    let height: Int
    let colorSpace: CGColorSpace

    /// The window server treats the live layer's pixels as sRGB, and a scene's still is sRGB too (image(fromBGRA:)).
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
}

enum StillRendering {
    enum Failure: Swift.Error {
        case noFrame, encode
    }

    /// Draws the scene `time` seconds in with these options into every canvas, one after the other, handing each
    /// picture to `deliver` with the canvas's index. One renderer serves all of them.
    static func renderScene(path: String, options: WallpaperOptions, at time: Double = 1, into canvases: [StillCanvas],
                            deliver: (Int, CGImage) throws -> Void) throws {
        // No script storage: a still must not write what the live scene keeps.
        let renderer = try Renderer(pkgPath: path, storagePath: nil)
        defer { renderer.stop() }
        renderer.setMuted(muted: true)
        // A clock or date the scene computes would stay frozen in the still.
        renderer.setHideScriptedText(hide: true)
        renderer.setFraming(framing: options.framing)
        renderer.setColorGrade(grade: options.colorGrade)
        renderer.applyAntialiasing(samples: options.antialiasing ? 4 : 1)
        for (name, value) in options.properties.sorted(by: { $0.key < $1.key }) {
            renderer.applyProperty(name: name, valueJson: value.json)
        }
        // Particles, scripts and animations advance frame by frame, so every frame before `time` is drawn, at the
        // 30 per second the renderer steps an off-screen frame by; the warm-up frames are tiny.
        renderer.setFrameSize(width: 160, height: 90)
        for frame in 0..<Int((time * 30).rounded()) {
            try Task.checkCancellation()
            _ = try renderer.renderFrame(time: Double(frame) / 30)
        }
        for (index, canvas) in canvases.enumerated() {
            try Task.checkCancellation()
            renderer.setFrameSize(width: UInt32(canvas.width), height: UInt32(canvas.height))
            let pixels = try renderer.renderFrame(time: time)
            try deliver(index, image(fromBGRA: pixels, of: canvas))
        }
    }

    /// The video's still frame `time` seconds in (VideoStills) through the colour options and image filter, like the
    /// player's video composition. `maxPixelSize` nil = the video's own size.
    static func videoFrame(path: String, options: WallpaperOptions, at time: Double = 1,
                           maxPixelSize: CGSize?) async throws -> CGImage {
        guard let frame = await VideoStills.cgImage(for: URL(fileURLWithPath: path), at: time,
                                                    maxPixelSize: maxPixelSize) else {
            throw Failure.noFrame
        }
        let grader = VideoGrader()
        guard grader.update(options) else { return frame }
        let image = grader.apply(CIImage(cgImage: frame))
        guard let graded = VideoGrader.context.createCGImage(image, from: image.extent) else { throw Failure.encode }
        return graded
    }

    /// The renderer's BGRA pixels carry no colour space; they are taken as the canvas's (sRGB for every scene still).
    private static func image(fromBGRA pixels: Data, of canvas: StillCanvas) throws -> CGImage {
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: canvas.width, height: canvas.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: canvas.width * 4, space: canvas.colorSpace,
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent)
        else { throw Failure.encode }
        return image
    }

    /// The video frame placed on the canvas like the player places it (VideoPlacement), with the blurred copy
    /// behind it where the alignment leaves bars.
    static func place(_ frame: CGImage, _ options: WallpaperOptions, into canvas: StillCanvas) throws -> CGImage {
        let context = try context(for: canvas)
        let size = CGSize(width: canvas.width, height: canvas.height)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let content = CGSize(width: frame.width, height: frame.height)
        let cover = WallpaperOptions(alignment: .cover)
        guard let placement = VideoPlacement(options, content: content, target: size)
                ?? VideoPlacement(cover, content: content, target: size) else { throw Failure.encode }
        if placement.blurredBars, let backdrop = blurred(frame) {
            let covered = VideoPlacement(cover, content: content, target: size)?.frame ?? CGRect(origin: .zero, size: size)
            draw(backdrop, in: covered, flipped: placement.flipped, on: context, height: size.height)
        }
        draw(frame, in: placement.frame, flipped: placement.flipped, on: context, height: size.height)
        guard let image = context.makeImage() else { throw Failure.encode }
        return image
    }

    /// `image` scaled to fill the canvas.
    static func scaled(_ image: CGImage, to canvas: StillCanvas) throws -> CGImage {
        let context = try context(for: canvas)
        context.draw(image, in: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        guard let scaled = context.makeImage() else { throw Failure.encode }
        return scaled
    }

    private static func context(for canvas: StillCanvas) throws -> CGContext {
        guard let context = CGContext(data: nil, width: canvas.width, height: canvas.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: canvas.colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw Failure.encode }
        context.interpolationQuality = .high
        return context
    }

    /// Draws `image` into `frame` (origin at the top-left, as VideoPlacement counts), mirrored when `flipped`.
    private static func draw(_ image: CGImage, in frame: CGRect, flipped: Bool, on context: CGContext,
                             height: CGFloat) {
        context.saveGState()
        context.translateBy(x: frame.midX, y: height - frame.midY)
        context.scaleBy(x: flipped ? -1 : 1, y: 1)
        context.draw(image, in: CGRect(x: -frame.width / 2, y: -frame.height / 2, width: frame.width, height: frame.height))
        context.restoreGState()
    }

    /// A strongly blurred copy of `image`, for the bars.
    private static func blurred(_ image: CGImage) -> CGImage? {
        let source = CIImage(cgImage: image)
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: Double(max(image.width, image.height)) / 60)
            .cropped(to: source.extent)
        return VideoGrader.context.createCGImage(blurred, from: source.extent)
    }

    /// Written under a temporary name first, so a half-written file is never taken for a finished one.
    static func write(_ image: CGImage, to url: URL, as type: UTType, quality: Double) throws {
        let partial = url.appendingPathExtension("partial")
        guard let destination = CGImageDestinationCreateWithURL(partial as CFURL, type.identifier as CFString, 1, nil)
        else { throw Failure.encode }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: partial)
            throw Failure.encode
        }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
    }
}
