import Foundation

// Owner: SCENEPARSE. `.tex` texture container decoding (SPEC3.md section 5.2). Pixels are NOT uploaded here:
// the decoder returns the payload as stored (raw pixels, BC-compressed blocks, or an encoded PNG/JPEG/MP4 file)
// after LZ4 decompression, so the renderer can keep DXT data compressed on the GPU.

/// Pixel layout of a mipmap's bytes when the payload is not an encoded image.
public enum TexPixelFormat: Equatable, Sendable {
    case rgba8888      // 4 bytes per pixel, R G B A
    case rg88          // 2 bytes per pixel
    case r8            // 1 byte per pixel
    case dxt1          // BC1, 8 bytes per 4x4 block
    case dxt3          // BC2, 16 bytes per block
    case dxt5          // BC3, 16 bytes per block
}

public enum TexPayload: Equatable, Sendable {
    case pixels(TexPixelFormat)
    case image(fileExtension: String)     // "png", "jpg", ...: the mipmap bytes are a complete image file
    case video(fileExtension: String)     // "mp4": an animated texture; M0 treats the scene as partial
}

public struct TexFlags: OptionSet, Equatable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let noInterpolation = TexFlags(rawValue: 1)
    public static let clampUVs = TexFlags(rawValue: 2)
    public static let isGif = TexFlags(rawValue: 4)            // sprite sheet with frame table
    public static let isVideoTexture = TexFlags(rawValue: 32)
}

public struct TexMipmap: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var data: Data                // decompressed

    public init(width: Int, height: Int, data: Data) {
        self.width = width
        self.height = height
        self.data = data
    }
}

/// One entry of the sprite-sheet frame table (flag `isGif`).
public struct TexFrame: Equatable, Sendable {
    public var imageIndex: Int
    public var seconds: Double           // display time
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(imageIndex: Int, seconds: Double, x: Double, y: Double, width: Double, height: Double) {
        self.imageIndex = imageIndex
        self.seconds = seconds
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct TexImage: Equatable, Sendable {
    public var textureWidth: Int         // size of the stored texture (power-of-two padded)
    public var textureHeight: Int
    public var imageWidth: Int           // size of the picture inside it
    public var imageHeight: Int
    public var flags: TexFlags
    public var payload: TexPayload
    public var mipmaps: [TexMipmap]      // of the first image; [0] is the full resolution
    public var frames: [TexFrame]        // empty unless flags contains .isGif
    public var containerMagic: String    // "TEXB0001" ... "TEXB0004"

    public init(textureWidth: Int, textureHeight: Int, imageWidth: Int, imageHeight: Int, flags: TexFlags,
                payload: TexPayload, mipmaps: [TexMipmap], frames: [TexFrame] = [], containerMagic: String = "") {
        self.textureWidth = textureWidth
        self.textureHeight = textureHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.flags = flags
        self.payload = payload
        self.mipmaps = mipmaps
        self.frames = frames
        self.containerMagic = containerMagic
    }
}

public enum LZ4 {
    /// LZ4 block format (no frame header), as used inside `.tex` mipmaps.
    public static func decompress(_ source: Data, decompressedSize: Int) throws -> Data {
        throw SceneFormatError.notImplemented("LZ4.decompress")
    }
}

public enum TexDecoder {
    /// Parses a complete `.tex` file. Counts and sizes are range checked (hostile input must not crash or allocate
    /// gigabytes): at most 1 image, 16 mipmaps, 64k x 64k pixels, 512 MB of mipmap bytes.
    public static func decode(_ data: Data) throws -> TexImage {
        throw SceneFormatError.notImplemented("TexDecoder.decode")
    }
}
