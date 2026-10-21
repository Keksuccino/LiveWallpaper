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
    private var textures: [String: Entry] = [:]
    private var drawEpoch = 0
    private let budgetBytes: Int

    private struct Entry {
        var texture: MTLTexture
        var bytes: Int
        var lastDrawn: Int
    }

    init(budgetBytes: Int) {
        self.budgetBytes = max(0, budgetBytes)
    }

    /// Loads the first mipmap of `path` (LRU-cached). `content` is the raw `.tex` bytes.
    /// Returns nil when the texture cannot be produced (video payload, decode failure) — the layer is skipped.
    func texture(for path: String, content: Data, device: MTLDevice) -> MTLTexture? {
        if let entry = textures[path] {
            drawEpoch += 1
            textures[path]?.lastDrawn = drawEpoch
            return entry.texture
        }
        guard let image = try? TexDecoder.decode(content), let mip = image.mipmaps.first,
              let texture = upload(mip, of: image, device: device) else { return nil }
        let bytes = texture.allocatedSize
        evict(dateSpaceFor: bytes)
        drawEpoch += 1
        textures[path] = Entry(texture: texture, bytes: bytes, lastDrawn: drawEpoch)
        residentBytes += bytes
        return texture
    }

    /// A still image (the scene preview) as a texture, without touching the budget (one texture, released with
    /// everything else).
    func texture(image: CGImage, device: MTLDevice) -> MTLTexture? {
        let context = imageContext(image)
        guard let pixels = context?.data else { return nil }
        return uploadPixels(pixels.assumingMemoryBound(to: UInt8.self), width: image.width, height: image.height,
                            bytesPerRow: image.width * 4, format: .rgba8Unorm, device: device)
    }

    func removeAll() {
        textures.removeAll()
        residentBytes = 0
        drawEpoch += 1
    }

    // MARK: internals

    private func evict(dateSpaceFor bytes: Int) {
        guard budgetBytes > 0, residentBytes + bytes > budgetBytes else { return }
        let oldestFirst = textures.sorted { $0.value.lastDrawn < $1.value.lastDrawn }
        var resident = residentBytes
        for (path, entry) in oldestFirst {
            if resident + bytes <= budgetBytes { break }
            resident -= entry.bytes
            textures[path] = nil
        }
        residentBytes = resident
    }

    private func upload(_ mip: TexMipmap, of image: TexImage, device: MTLDevice) -> MTLTexture? {
        switch image.payload {
        case .pixels(let format):
            let perRow: Int
            switch format {
            case .rgba8888: perRow = mip.width * 4
            case .rg88: perRow = mip.width * 2
            case .r8: perRow = mip.width
            case .dxt1: perRow = max(1, (mip.width + 3) / 4) * 8
            case .dxt3, .dxt5: perRow = max(1, (mip.width + 3) / 4) * 16
            }
            let mtlFormat: MTLPixelFormat
            switch format {
            case .rgba8888: mtlFormat = .rgba8Unorm
            case .rg88: mtlFormat = .rg8Unorm
            case .r8: mtlFormat = .r8Unorm
            case .dxt1: mtlFormat = .bc1_rgba
            case .dxt3: mtlFormat = .bc2_rgba
            case .dxt5: mtlFormat = .bc3_rgba
            }
            return mip.data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                guard let base = raw.baseAddress else { return nil }
                return uploadPixels(base.assumingMemoryBound(to: UInt8.self), width: mip.width, height: mip.height,
                                    bytesPerRow: perRow, format: mtlFormat, device: device)
            }
        case .image(let ext):
            return texture(image: decodedImage(mip.data, ext: ext), device: device)
        case .video:
            return nil
        }
    }

    private func decodedImage(_ data: Data, ext: String) -> CGImage {
        _ = ext
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, options) else {
            return solidImage()
        }
        return decoded
    }

    /// A 1x1 transparent fallback keeps a broken texture from taking the whole scene down.
    private func solidImage() -> CGImage {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        return context!.makeImage()!
    }

    /// Draws any CGImage into RGBA bytes; returns nil for sizes the engine refuses.
    private func imageContext(_ image: CGImage) -> CGContext? {
        let width = image.width, height = image.height
        guard width > 0, height > 0, width <= TexDecoder.self.maxDimension, height <= TexDecoder.self.maxDimension,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    private func uploadPixels(_ bytes: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int,
                              format: MTLPixelFormat, device: MTLDevice) -> MTLTexture? {
        guard width > 0, height > 0 else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0), size: MTLSize(width: width, height: height,
                                                                                  depth: 1))
        texture.replace(region: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: bytesPerRow)
        return texture
    }
}
