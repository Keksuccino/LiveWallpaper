import AppKit
import QuartzCore

// What a scene is drawn in. Our renderer draws into a CAMetalLayer that the app hands over, so the app keeps
// control of the window (DisplayWindow): its level, the spaces and the occlusion state.

/// A view whose backing layer is a CAMetalLayer, so the renderer can draw into it.
final class MetalView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true  // after super.init, so makeBackingLayer() is what creates the layer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    var metalLayer: CAMetalLayer? { layer as? CAMetalLayer }
}

/// The display a scene is drawn on.
struct SceneDisplay: Equatable {
    /// The display's UUID, which the renderer attaches and detaches the layer by.
    let id: String
    let layer: CAMetalLayer
    /// Size of the drawable in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
}

extension DisplayWindow where View == MetalView {
    /// The window's layer with its size in pixels (the layer's scale follows the screen's); nil while the window is
    /// not on screen.
    func display() -> SceneDisplay? {
        guard let window, let layer = view?.metalLayer else { return nil }
        let scale = window.screen?.backingScaleFactor ?? 1
        layer.contentsScale = scale
        let size = window.frame.size
        return SceneDisplay(
            id: displayID,
            layer: layer,
            pixelWidth: Int((size.width * scale).rounded()),
            pixelHeight: Int((size.height * scale).rounded())
        )
    }
}
