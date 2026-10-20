import Foundation
import Metal

// Owner: SCENERENDER. Metal Shading Language sources, compiled at runtime with `MTLDevice.makeLibrary(source:options:)`.
// They are Swift string literals on purpose: SwiftPM command line builds need no .metal compile rules, no resource
// bundle and no metallib lookup, which keeps the executable bundle layout of build.sh unchanged.
// M0 needs: a textured quad (vertex: layer transform + parallax offset; fragment: sample * tint, premultiplied),
// the blend states (normal, opaque, additive, multiply, screen) and a copy/crossfade pass for LoopPlan.
// Pipeline caches are keyed by (BlendMode, pixelFormat).

enum SceneShaderSource {
    /// Placeholder so the target links; replaced by the real M0 source.
    static let m0 = """
    #include <metal_stdlib>
    using namespace metal;
    """
}
