import AppKit
import QuartzCore
import Core

// How a playlist's next wallpaper takes over a display (PlaylistTransition). The next wallpaper's window opens
// transparent above the current one (DisplayWindow); once the wallpaper in it is ready, the transition animates the two
// windows' stages with Core Animation, presents the new window and hands back, and the DisplayPlayer stops the old
// wallpaper. Both keep playing meanwhile. Only the stages are animated, never the views a renderer or player draws
// into, and the animations run in the window server, so they cost the service nothing per frame.

@MainActor final class WallpaperTransition {
    /// Blur radius in points at the height of the blur transition.
    private static let blurRadius = 36.0
    /// How much larger the next wallpaper starts in the zoom transition.
    private static let zoomScale = 1.08

    private let kind: PlaylistTransition
    private let duration: Double
    private let outgoing: TransitionWindow
    private let incoming: TransitionWindow
    private var done: (() -> Void)?
    private var timer: Task<Void, Never>?

    /// `done` runs once, when the transition has ended or was cut short (`finish`).
    init(_ kind: PlaylistTransition, duration: Double, from outgoing: TransitionWindow, to incoming: TransitionWindow,
         done: @escaping () -> Void) {
        // Reduce Motion: wallpapers that move or grow fade instead.
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        self.kind = reduceMotion && (kind == .zoom || kind == .slide) ? .fade : kind
        self.duration = duration
        self.outgoing = outgoing
        self.incoming = incoming
        self.done = done
    }

    func run() {
        guard kind != .cut, duration > 0,
              let inWindow = incoming.window, let inStage = incoming.stage,
              let outWindow = outgoing.window, let outStage = outgoing.stage else {
            finish()
            return
        }
        incoming.isTransitioning = true
        outgoing.isTransitioning = true
        // The new window has to be above the old one, also when the old one was made again since (a screen change).
        inWindow.order(.above, relativeTo: outWindow.windowNumber)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        animate(in: inStage, out: outStage)
        CATransaction.commit()
        let nanoseconds = UInt64(duration * 1_000_000_000)
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: nanoseconds) } catch { return }
            self?.finish()
        }
    }

    /// Ends the transition at once (or after it ran): the new wallpaper is presented in full, the old stage back to
    /// normal. Calling it again does nothing.
    func finish() {
        timer?.cancel()
        timer = nil
        guard let done else { return }
        self.done = nil
        for window in [outgoing, incoming] {
            if let stage = window.stage { Self.reset(stage) }
            window.isTransitioning = false
        }
        incoming.present()
        done()
    }

    // MARK: Animations

    /// Each animation runs from the start values to the end values over the whole duration (key times are fractions
    /// of it); the layers' own values are set to the end values first, which they keep when the animation is removed.
    private func animate(in inStage: StageView, out outStage: StageView) {
        guard let inLayer = inStage.layer, let outLayer = outStage.layer else { return }
        // The stage was hidden until now (DisplayWindow.isPresented); from here the animations decide what shows.
        inStage.alphaValue = 1
        switch kind {
        case .cut:
            break
        case .fade:
            animate(inLayer, "opacity", [0, 1], [0, 1])
        case .fadeThroughBlack:
            // The new stage brings its own black: it fades in black first, then its wallpaper on top of the black.
            inLayer.backgroundColor = NSColor.black.cgColor
            animate(inLayer, "opacity", [0, 1, 1], [0, 0.5, 1])
            if let content = inStage.content.layer { animate(content, "opacity", [0, 0, 1], [0, 0.5, 1]) }
        case .blur:
            let r = Self.blurRadius
            Self.addBlur(to: outStage)
            Self.addBlur(to: inStage)
            animate(outLayer, Self.blurKey, [0, r, r], [0, 0.5, 1])
            animate(inLayer, Self.blurKey, [r, r, 0], [0, 0.4, 1])
            animate(inLayer, "opacity", [0, 0, 1, 1], [0, 0.2, 0.6, 1])
        case .zoom:
            animate(inLayer, "opacity", [0, 1, 1], [0, 0.6, 1])
            animate(inLayer, "sublayerTransform", [Self.scale(Self.zoomScale, inStage), Self.scale(1, inStage)], [0, 1],
                    timing: CAMediaTimingFunction(name: .easeOut))
            // The old wallpaper grows a little too, so the two move together.
            let grown = 1 + (Self.zoomScale - 1) / 2
            animate(outLayer, "sublayerTransform", [Self.scale(1, outStage), Self.scale(grown, outStage)], [0, 1])
        case .slide:
            let width = inStage.bounds.width
            animate(inLayer, "sublayerTransform", [Self.shift(width), Self.shift(0)], [0, 1])
            animate(outLayer, "sublayerTransform", [Self.shift(0), Self.shift(-width)], [0, 1])
        }
    }

    /// Animates `keyPath` of `layer` through `values` at `times` (fractions of the duration), ending on the last value.
    private func animate(_ layer: CALayer, _ keyPath: String, _ values: [Any], _ times: [Double],
                         timing: CAMediaTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)) {
        layer.setValue(values.last, forKeyPath: keyPath)
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = times.map { NSNumber(value: $0) }
        animation.timingFunctions = Array(repeating: timing, count: max(values.count - 1, 1))
        animation.duration = duration
        layer.add(animation, forKey: keyPath)
    }

    // MARK: Stage helpers

    private static let blurKey = "filters.blur.inputRadius"

    /// A blur the transition animates by name (`blurKey`). Keep it a single plain Gaussian blur: Core Animation renders
    /// a filter chain with an unbounded filter in it (such as CIAffineClamp, to keep the edges from fading) at the wrong
    /// scale over a Metal or video layer, which shows the wallpaper shrunk into a corner with its edges smeared.
    private static func addBlur(to stage: StageView) {
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.setDefaults()
        blur.name = "blur"
        blur.setValue(0, forKey: kCIInputRadiusKey)
        stage.contentFilters = [blur]
    }

    /// Scales the stage's content about the stage's centre. The sublayer transform applies about the layer's anchor
    /// point, which AppKit puts at the layer's origin, so the centre is moved to the anchor and back.
    private static func scale(_ factor: Double, _ stage: StageView) -> NSValue {
        let bounds = stage.layer?.bounds ?? stage.bounds
        let anchor = stage.layer?.anchorPoint ?? .zero
        let x = bounds.midX - anchor.x * bounds.width
        let y = bounds.midY - anchor.y * bounds.height
        var transform = CATransform3DMakeTranslation(x, y, 0)
        transform = CATransform3DScale(transform, factor, factor, 1)
        transform = CATransform3DTranslate(transform, -x, -y, 0)
        return NSValue(caTransform3D: transform)
    }

    private static func shift(_ x: Double) -> NSValue {
        NSValue(caTransform3D: CATransform3DMakeTranslation(x, 0, 0))
    }

    /// The stage as a window shows it outside transitions.
    private static func reset(_ stage: StageView) {
        stage.layer?.removeAllAnimations()
        stage.content.layer?.removeAllAnimations()
        stage.contentFilters = []
        stage.layer?.sublayerTransform = CATransform3DIdentity
        stage.layer?.backgroundColor = nil
        stage.content.alphaValue = 1
    }
}
