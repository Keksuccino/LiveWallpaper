import Foundation

// Scaffold-owned (frozen, complete): the arithmetic of the seamless lock screen loop.
// A scene is a function f(t) of time. The output video has `loopFrames` frames. For output frame i at t = i / fps:
//   - i >= crossfadeFrames:  out(i) = f(t)
//   - i <  crossfadeFrames:  out(i) = (1 - a) * f(t + T) + a * f(t)   with a = i / crossfadeFrames, T = loop length
// so the last frame f(T - 1/fps) is followed by out(0) = f(T): no jump at the seam, for any f. The renderer must
// therefore be able to render times up to T + crossfade. A scene with its own exact period uses crossfade 0.

public struct LoopPlan: Equatable, Sendable {
    public struct Source: Equatable, Sendable {
        public var primary: Double       // scene time of the main layer
        public var secondary: Double?    // scene time of the layer faded in over the first frames; nil = none
        public var mix: Float            // weight of `secondary` in 0...1 (0 when secondary is nil)

        public init(primary: Double, secondary: Double? = nil, mix: Float = 0) {
            self.primary = primary
            self.secondary = secondary
            self.mix = mix
        }
    }

    public let fps: Int
    public let loopFrames: Int
    public let crossfadeFrames: Int

    public var loopSeconds: Double { Double(loopFrames) / Double(fps) }
    public var crossfadeSeconds: Double { Double(crossfadeFrames) / Double(fps) }
    /// Number of times the renderer is asked for a frame (the crossfade frames need two).
    public var renderCalls: Int { loopFrames + crossfadeFrames }

    public init(loopSeconds: Double, crossfadeSeconds: Double, fps: Int) {
        let safeFPS = max(1, min(fps, 120))
        let frames = max(2, Int((loopSeconds * Double(safeFPS)).rounded()))
        let fade = max(0, min(Int((crossfadeSeconds * Double(safeFPS)).rounded()), frames / 2))
        self.fps = safeFPS
        self.loopFrames = frames
        self.crossfadeFrames = fade
    }

    public func source(forFrame i: Int) -> Source {
        let t = Double(i) / Double(fps)
        guard i >= 0, i < crossfadeFrames else { return Source(primary: t) }
        let a = Float(i) / Float(crossfadeFrames)
        return Source(primary: t, secondary: t + loopSeconds, mix: 1 - a)
    }

    /// Picks the loop length. A known period is repeated until the video lasts at least 10 s (never more than 40 s)
    /// and needs no crossfade; otherwise 20 s with a 2 s crossfade.
    public static func choose(scenePeriod: Double?, fps: Int) -> LoopPlan {
        if let period = scenePeriod, period >= 1, period <= 40 {
            let repeats = max(1, Int((10 / period).rounded(.up)))
            let length = min(40, period * Double(repeats))
            return LoopPlan(loopSeconds: length, crossfadeSeconds: 0, fps: fps)
        }
        return LoopPlan(loopSeconds: 20, crossfadeSeconds: 2, fps: fps)
    }
}
