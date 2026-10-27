import SwiftUI
import AppKit
import ImageIO

// Pictures that may be animations (Workshop previews are often GIFs) and the view that plays them.
// SwiftUI's Image and AsyncImage show only the first frame.
//
// A still is decoded once, scaled down to the size it is shown at. An animation keeps its encoded bytes; when a view
// starts playing it, every frame is decoded once, off the main thread, and handed to Core Animation as a keyframe
// animation, which the render server plays without waking the app. Decoding each frame when it is due (ImageIO's
// CGAnimateImageDataWithBlock) costs a GIF decode and a layer commit on the main thread per frame, several percent of
// a core per playing preview; the decoded frames cost memory instead, so they are cropped to what the view shows and
// let go of whenever the view stops playing.

/// A picture ready to show: its first frame, and its encoded bytes when it is an animation.
final class AnimatedPicture: Sendable {
    /// Every frame of an animation, decoded for Core Animation, and when each one starts.
    struct Frames: Sendable {
        let images: [CGImage]
        /// Each frame's start, as a fraction of `duration`, and 1 at the end: the key times of a discrete animation.
        let keyTimes: [Double]
        let duration: CFTimeInterval

        /// The frame shown `time` seconds into a loop.
        func image(at time: CFTimeInterval) -> CGImage {
            images[keyTimes.dropLast().lastIndex { $0 <= time / duration } ?? 0]
        }
    }

    /// The most memory one animation's decoded frames may take; larger ones are decoded smaller.
    private static let frameBudget = 16 << 20

    /// The first frame, upright, decoded in full and at most `maxPixelSize` on its longest side (never enlarged).
    let poster: CGImage
    /// The encoded picture when it has more than one frame.
    let animation: Data?
    let maxPixelSize: Int

    /// The memory it holds, for caches.
    var cost: Int { poster.bytesPerRow * poster.height + (animation?.count ?? 0) }

    /// Nil when `data` is no picture. Decodes the first frame: never call it on the main thread.
    init?(data: Data, maxPixelSize: Int) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let poster = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        self.poster = poster
        self.maxPixelSize = maxPixelSize
        animation = CGImageSourceGetCount(source) > 1 ? data : nil
    }

    /// Decodes every frame of the animation, cropped to the middle part of `aspect` (width / height) when given, at
    /// most `maxPixelSize` on its longest side and all frames within `frameBudget`. Nil for a still, or when the task
    /// is cancelled. Takes a moment: never call it on the main thread.
    func frames(croppedTo aspect: CGFloat?) -> Frames? {
        // Uncached: each frame is drawn into its own bitmap right away, the source's copy would only double the memory.
        let uncached = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let animation, let source = CGImageSourceCreateWithData(animation as CFData, nil),
              let first = CGImageSourceCreateImageAtIndex(source, 0, uncached) else { return nil }
        let count = CGImageSourceGetCount(source)
        let canvas = CGSize(width: first.width, height: first.height)
        var crop = CGRect(origin: .zero, size: canvas)
        if let aspect, aspect > 0 {
            if canvas.width / canvas.height > aspect {
                crop.size.width = (canvas.height * aspect).rounded()
            } else {
                crop.size.height = (canvas.width / aspect).rounded()
            }
            crop.origin = CGPoint(x: ((canvas.width - crop.width) / 2).rounded(),
                                  y: ((canvas.height - crop.height) / 2).rounded())
        }
        let bytes = crop.width * crop.height * 4 * CGFloat(count)
        let scale = min(1, CGFloat(maxPixelSize) / max(crop.width, crop.height),
                        (CGFloat(Self.frameBudget) / bytes).squareRoot())
        let size = (width: max(1, Int((crop.width * scale).rounded())),
                    height: max(1, Int((crop.height * scale).rounded())))
        // The canvas drawn so that `crop` covers the frame (Core Graphics counts y from the bottom).
        let drawn = CGRect(x: -crop.minX * scale, y: -(canvas.height - crop.maxY) * scale,
                           width: canvas.width * scale, height: canvas.height * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        var images: [CGImage] = []
        var starts: [Double] = []
        var duration = 0.0
        images.reserveCapacity(count)
        for index in 0..<count {
            guard !Task.isCancelled else { return nil }
            guard let frame = index == 0 ? first : CGImageSourceCreateImageAtIndex(source, index, uncached),
                  let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo) else { return nil }
            context.interpolationQuality = .high
            context.draw(frame, in: drawn)
            guard let image = context.makeImage() else { return nil }
            images.append(image)
            starts.append(duration)
            duration += Self.delay(of: index, in: source)
        }
        return Frames(images: images, keyTimes: starts.map { $0 / duration } + [1], duration: duration)
    }

    /// How long frame `index` shows. Like browsers, a delay of 10 ms or less counts as 100 ms: such files expect it.
    private static func delay(of index: Int, in source: CGImageSource) -> Double {
        let keys: [(dictionary: CFString, delay: CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSDelayTime),
        ]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        for key in keys {
            if let delay = (properties?[key.dictionary] as? [CFString: Any])?[key.delay] as? Double {
                return delay > 0.01 ? delay : 0.1
            }
        }
        return 0.1
    }
}

/// A plain EnvironmentKey: the `@Entry` macro needs a macro plugin the Command Line Tools toolchain does not ship.
private struct AnimatedPicturesPlayKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether the AnimatedPictureViews below may play. Off where they stay in the view tree but cannot be seen.
    var animatedPicturesPlay: Bool {
        get { self[AnimatedPicturesPlayKey.self] }
        set { self[AnimatedPicturesPlayKey.self] = newValue }
    }
}

/// Shows an AnimatedPicture filling the space SwiftUI proposes, cropped to it with its aspect ratio kept, and plays an
/// animation, looping, while `playing`, `animatedPicturesPlay` and the system's Play Animated Images allow it and its
/// window can be seen. A paused animation keeps its frame and goes on from there.
struct AnimatedPictureView: NSViewRepresentable {
    let picture: AnimatedPicture
    var playing = true

    func makeNSView(context: Context) -> AnimatedPictureLayerView { AnimatedPictureLayerView() }

    func updateNSView(_ view: AnimatedPictureLayerView, context: Context) {
        let environment = context.environment
        view.show(picture,
                  playing: playing && environment.animatedPicturesPlay && environment.accessibilityPlayAnimatedImages)
    }

    static func dismantleNSView(_ view: AnimatedPictureLayerView, coordinator: ()) { view.stopPlaying() }

    /// Takes the size SwiftUI proposes: a view asking for the picture's pixel size would push its container apart.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AnimatedPictureLayerView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }
}

/// AnimatedPictureView's NSView. The frame shown is its layer's contents; while it plays, a keyframe animation of
/// them, which Core Animation runs on its own.
final class AnimatedPictureLayerView: NSView {
    private static let animationKey = "frames"

    private struct Playing {
        let frames: AnimatedPicture.Frames
        let since: CFTimeInterval
    }

    private var picture: AnimatedPicture?
    private var shown: CGImage?
    private var wantsPlaying = false
    private var decoding: Task<Void, Never>?
    private var playing: Playing?
    /// How far into its loop the animation is, in seconds, when it does not play.
    private var phase: CFTimeInterval = 0
    private var occlusionObserver: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layerContentsPlacement = .scaleProportionallyToFill   // the layer's resizeAspectFill gravity
        clipsToBounds = true   // the filling picture is larger than the view
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }

    /// AppKit's own redraws keep the frame shown.
    override func updateLayer() { layer?.contents = shown }

    func show(_ picture: AnimatedPicture, playing: Bool) {
        if picture !== self.picture {
            stopPlaying()
            self.picture = picture
            phase = 0
            display(picture.poster)
        }
        wantsPlaying = playing
        updatePlayback()
    }

    /// Stops the animation on the frame it shows and lets go of its frames.
    func stopPlaying() {
        decoding?.cancel()
        decoding = nil
        guard let playing else { return }
        phase = (phase + CACurrentMediaTime() - playing.since).truncatingRemainder(dividingBy: playing.frames.duration)
        display(playing.frames.image(at: phase))
        layer?.removeAnimation(forKey: Self.animationKey)
        self.playing = nil
    }

    /// Plays only in a window that can be seen: not minimised, hidden or covered.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = window.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window,
                                                   queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updatePlayback() }
            }
        }
        updatePlayback()
    }

    private func display(_ frame: CGImage) {
        shown = frame
        layer?.contents = frame
    }

    private func updatePlayback() {
        let play = wantsPlaying && picture?.animation != nil && window?.occlusionState.contains(.visible) == true
        if !play { stopPlaying() } else if playing == nil, decoding == nil { startPlaying() }
    }

    /// Decodes the frames, cropped to the view's shape, then plays them.
    private func startPlaying() {
        guard let picture else { return }
        let aspect = bounds.height > 0 ? bounds.width / bounds.height : nil
        let decode = Task.detached(priority: .userInitiated) { picture.frames(croppedTo: aspect) }
        decoding = Task { [weak self] in
            let frames = await withTaskCancellationHandler { await decode.value } onCancel: { decode.cancel() }
            guard !Task.isCancelled, let self else { return }
            decoding = nil
            if let frames { play(frames) }
        }
    }

    private func play(_ frames: AnimatedPicture.Frames) {
        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = frames.images
        animation.keyTimes = frames.keyTimes.map { NSNumber(value: $0) }
        animation.calculationMode = .discrete
        animation.duration = frames.duration
        animation.repeatCount = .infinity
        animation.timeOffset = phase
        animation.isRemovedOnCompletion = false
        layer?.add(animation, forKey: Self.animationKey)
        playing = Playing(frames: frames, since: CACurrentMediaTime())
    }
}
