import Foundation

// The parts of a `scene.json` the library's analysis reads (SceneAnalyzer): the design size and the texture of every
// image layer, with model/material/texture paths already resolved against the scene's files.

struct SceneDocument: Equatable, Sendable {
    /// The orthogonal projection's size.
    var designWidth: Double = 1920
    var designHeight: Double = 1080
    /// Every object that draws an image, in file order.
    var imageLayers: [ImageLayer] = []
}

struct ImageLayer: Equatable, Sendable {
    /// The object is visible and not fully transparent.
    var shown: Bool
    /// The first texture of the material's first pass; nil when the model, the material or the texture is missing.
    var texturePath: String?
}
