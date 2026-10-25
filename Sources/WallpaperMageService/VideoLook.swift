import AppKit
import CoreImage
import os
import Core
import SceneBridge

// Wallpaper Engine's options for a video: where its picture sits (the renderer's framing math, so a video is placed
// exactly like a scene) and its colour options and image filter (Core Image, the same steps as the renderer's grade
// pass). Used by the live player (WallpaperWindows) and by the stills (WallpaperStills).

/// Where a video's picture lands on its display.
struct VideoPlacement: Equatable {
    /// The picture's rectangle in the target, origin at the top-left, in the target's units.
    var frame: CGRect
    /// Mirrored left to right.
    var flipped: Bool
    /// Part of the target is not covered and the options ask for a blurred copy behind the picture.
    var blurredBars: Bool

    /// `content` (the video's pixel size) placed in `target` (in pixels). nil when either is empty.
    init?(_ options: WallpaperOptions, content: CGSize, target: CGSize) {
        guard content.width > 0, content.height > 0, target.width > 0, target.height > 0 else { return nil }
        let view = framingView(framing: options.framing, designWidth: Float(content.width),
                               designHeight: Float(content.height), targetWidth: Float(target.width),
                               targetHeight: Float(target.height)).map(Double.init)
        guard view.count == 4, view[1] != view[0], view[3] != view[2] else { return nil }
        let (l, r, t, b) = (view[0], view[1], view[2], view[3])
        let x0 = -l / (r - l) * target.width, x1 = (content.width - l) / (r - l) * target.width
        let y0 = -t / (b - t) * target.height, y1 = (content.height - t) / (b - t) * target.height
        frame = CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0))
        flipped = r < l
        // Half a pixel of slack keeps a rounded exact fit from counting as bars.
        let covers = frame.minX <= 0.5 && frame.minY <= 0.5
            && frame.maxX >= target.width - 0.5 && frame.maxY >= target.height - 0.5
        blurredBars = options.blurBars && options.alignment.canLeaveBars && !covers
    }
}

/// Colour options and image filter for video frames. The player's video composition calls `apply` on its own
/// threads; `update` runs on the main actor.
final class VideoGrader: @unchecked Sendable {
    /// What `apply` does; nil parts are off.
    private struct Grade {
        /// Value scale, contrast, saturation scale, hue shift (turns).
        var adjust: CIVector?
        /// RGBA float cube data of the filter, already mixed with the identity by its strength.
        var cube: Data?
        var cubeSize = 0
    }

    /// The colour space the grade works in: the gamma-encoded values Wallpaper Engine's pass works on.
    static let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    private let grade = OSAllocatedUnfairLock(initialState: Grade())
    /// The filter's table as loaded (name, size, texels), kept so a strength change needs no reload.
    private var table: (name: String, size: Int, rgba: [UInt8])?
    private var strength = -1.0

    /// Takes the options' colour values. Returns whether frames change at all.
    @discardableResult
    func update(_ options: WallpaperOptions) -> Bool {
        let adjust: CIVector? = options.adjustsColor ? Self.parameters(options) : nil
        if let name = options.filter, options.filterStrength > 0 {
            if table?.name != name {
                table = Self.loadTable(name).map { (name, $0.size, $0.rgba) }
                strength = -1
            }
            if let table, options.filterStrength != strength {
                strength = options.filterStrength
                let cube = Self.cube(table.rgba, size: table.size, strength: options.filterStrength)
                grade.withLock { $0.cube = cube; $0.cubeSize = table.size }
            }
        } else {
            table = nil
            strength = -1
            grade.withLock { $0.cube = nil }
        }
        return grade.withLock { g in
            g.adjust = adjust
            return g.adjust != nil || g.cube != nil
        }
    }

    /// `image` with the current grade.
    func apply(_ image: CIImage) -> CIImage {
        let g = grade.withLock { $0 }
        var out = image
        if let adjust = g.adjust, let kernel = Self.kernel {
            out = kernel.apply(extent: out.extent, arguments: [out, adjust]) ?? out
        }
        if let cube = g.cube, let filter = CIFilter(name: "CIColorCube") {
            filter.setValue(out, forKey: kCIInputImageKey)
            filter.setValue(g.cubeSize, forKey: "inputCubeDimension")
            filter.setValue(cube, forKey: "inputCubeData")
            out = filter.outputImage ?? out
        }
        return out
    }

    /// Wallpaper Engine's mapping of its 0...100 sliders (50 = unchanged): brightness scales the HSV value by its
    /// square, contrast and saturation by their square roots (as the renderer's `set_grade`).
    private static func parameters(_ o: WallpaperOptions) -> CIVector {
        let value = o.brightness * 2, contrast = o.contrast * 2, saturation = o.saturation * 2
        return CIVector(x: value * value, y: contrast.squareRoot(), z: saturation.squareRoot(), w: o.hue - 0.5)
    }

    /// The renderer's lookup table `name` from Wallpaper Engine's shared assets.
    private static func loadTable(_ name: String) -> (size: Int, rgba: [UInt8])? {
        do {
            let table = try lookupTable(assets: AppPaths.sharedAssetsDirectory.path, name: name)
            return (Int(table.size), Array(table.rgba))
        } catch {
            NSLog("WallpaperMage: image filter \(name) unavailable: \(error)")
            return nil
        }
    }

    /// Core Image cube data: the table's texels as floats, mixed with the identity by `strength` (mixing the table
    /// mixes the result, since the cube is interpolated linearly).
    private static func cube(_ rgba: [UInt8], size: Int, strength: Double) -> Data {
        let k = Float(strength), step = 1 / Float(max(size - 1, 1))
        var floats = [Float](repeating: 1, count: size * size * size * 4)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let i = ((b * size + g) * size + r) * 4
                    let (ir, ig, ib) = (Float(r) * step, Float(g) * step, Float(b) * step)
                    floats[i] = ir + (Float(rgba[i]) / 255 - ir) * k
                    floats[i + 1] = ig + (Float(rgba[i + 1]) / 255 - ig) * k
                    floats[i + 2] = ib + (Float(rgba[i + 2]) / 255 - ib) * k
                }
            }
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// The colour options: contrast around mid grey, then value, saturation and hue in HSV, as the renderer's
    /// `wm_grade_fs`.
    private static let kernel: CIColorKernel? = {
        let source = """
            #include <metal_stdlib>
            #include <CoreImage/CoreImage.h>
            using namespace metal;
            extern "C" { namespace coreimage {
            float4 wm_video_grade(sample_t s, float4 p) {
                float3 c = mix(float3(0.5), s.rgb, p.y);
                float4 a = c.g < c.b ? float4(c.bg, -1.0, 2.0 / 3.0) : float4(c.gb, 0.0, -1.0 / 3.0);
                float4 q = c.r < a.x ? float4(a.xyw, c.r) : float4(c.r, a.yzx);
                float chroma = q.x - min(q.w, q.y);
                float3 hsv = float3(abs((q.w - q.y) / (6.0 * chroma + 1e-10) + q.z), chroma / (q.x + 1e-10), q.x);
                hsv.z *= p.x;
                hsv.y *= p.z;
                hsv.x += p.w;
                float3 k = abs(fract(hsv.xxx + float3(1.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
                return float4(hsv.z * mix(float3(1.0), saturate(k - 1.0), hsv.y), s.a);
            }
            }}
            """
        do {
            return try CIKernel.kernels(withMetalString: source).first as? CIColorKernel
        } catch {
            NSLog("WallpaperMage: video colour options unavailable: \(error)")
            return nil
        }
    }()
}
