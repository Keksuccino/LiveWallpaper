import AppKit
import QuartzCore

// What a scene is drawn in. Our renderer draws into a CAMetalLayer that the app hands over, so the app keeps
// control of the windows (DesktopWindows): their level, the spaces and the occlusion state.

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

/// One display the scene is drawn on.
struct SceneDisplay: Equatable {
    /// Stable id of the display, used to attach and detach the layer.
    let id: String
    let layer: CAMetalLayer
    /// Size of the drawable in pixels.
    let pixelWidth: Int
    let pixelHeight: Int
}

extension DesktopWindows where View == MetalView {
    /// The layer of every screen with its size in pixels (the layer's scale follows the screen's).
    func displays() -> [SceneDisplay] {
        entries.compactMap { entry -> SceneDisplay? in
            guard let layer = entry.view.metalLayer else { return nil }
            let scale = entry.window.screen?.backingScaleFactor ?? 1
            layer.contentsScale = scale
            let size = entry.window.frame.size
            return SceneDisplay(
                id: entry.id,
                layer: layer,
                pixelWidth: Int((size.width * scale).rounded()),
                pixelHeight: Int((size.height * scale).rounded())
            )
        }
    }
}
