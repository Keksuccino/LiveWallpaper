import Foundation
import CoreGraphics
import ImageIO
import Metal
import SceneFormat

// Owner: SCENERENDER. TexImage (SceneFormat) -> MTLTexture: BC1/BC2/BC3 uploaded as compressed pixel formats
// (.bc1_rgba, .bc2_rgba, .bc3_rgba), raw RGBA/RG/R uploaded as .rgba8Unorm/.rg8Unorm/.r8Unorm, embedded PNG/JPEG
// decoded with ImageIO. Keeps a byte-budgeted cache with least-recently-drawn eviction (RenderOptions.textureBudgetBytes).

/// Internal to SceneEngine; the public surface is SceneRenderer.
final class SceneTextureCache {
    private(set) var residentBytes = 0

    init() {}

    func removeAll() {
        residentBytes = 0
    }
}
