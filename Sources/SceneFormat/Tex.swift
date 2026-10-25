import Foundation

// `.tex` texture container decoding. Pixels are NOT uploaded here: the decoder returns the payload as stored (raw
// pixels, BC-compressed blocks, or an encoded PNG/JPEG/MP4 file) after LZ4 decompression, so the renderer can keep
// DXT data compressed on the GPU.

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

/// One entry of the sprite-sheet frame table (flag `isGif`). M0 shows frame 0 only.
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
    public var frames: [TexFrame]        // empty unless the container has a frame table
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

// MARK: - LZ4 block decompression

public enum LZ4 {
    public static let maxDecompressedSize = 512 * 1024 * 1024

    /// LZ4 block format (no frame header), as used inside `.tex` mipmaps. Every read and write is bounds-checked
    /// against both buffers (a crafted block must throw, not crash or allocate unbounded). Throws `.truncated`
    /// when the block ends early, `.invalid` when a range rule is broken.
    public static func decompress(_ source: Data, decompressedSize: Int) throws -> Data {
        guard decompressedSize >= 0, decompressedSize <= maxDecompressedSize else {
            throw SceneFormatError.invalid("LZ4 would decompress to \(decompressedSize) bytes")
        }
        guard decompressedSize > 0 else { return Data() }
        let src = [UInt8](source)
        var out = Data(count: decompressedSize)
        try src.withUnsafeBufferPointer { srcBuffer in
            try out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                guard let dst = raw.bindMemory(to: UInt8.self).baseAddress else {
                    throw SceneFormatError.truncated("the LZ4 output buffer is missing")
                }
                try lz4Decompress(srcBuffer, dst, decompressedSize)
            }
        }
        return out
    }
}

private func lz4Decompress(_ src: UnsafeBufferPointer<UInt8>, _ dst: UnsafeMutablePointer<UInt8>,
                           _ size: Int) throws {
    let srcCount = src.count
    var srcPos = 0
    var dstPos = 0

    func readByte() throws -> Int {
        guard srcPos < srcCount else { throw SceneFormatError.truncated("the LZ4 block ends early") }
        let value = Int(src[srcPos])
        srcPos += 1
        return value
    }
    func readShort() throws -> Int {
        guard srcPos + 2 <= srcCount else { throw SceneFormatError.truncated("the LZ4 match offset is cut off") }
        let value = Int(src[srcPos]) | Int(src[srcPos + 1]) << 8
        srcPos += 2
        return value
    }

    while dstPos < size {
        let token = try readByte()
        var literalLength = token >> 4
        if literalLength == 15 {
            var extra: Int
            repeat {
                extra = try readByte()
                literalLength += extra
                guard literalLength <= size else {
                    throw SceneFormatError.invalid("the LZ4 literal length is out of range")
                }
            } while extra == 255
        }
        guard literalLength <= size - dstPos, srcPos + literalLength <= srcCount else {
            throw SceneFormatError.truncated("the LZ4 literals overrun a buffer")
        }
        for index in 0..<literalLength {
            dst[dstPos] = src[srcPos + index]
            dstPos += 1
        }
        srcPos += literalLength

        guard dstPos < size else { break }
        let offset = try readShort()
        guard offset > 0, offset <= dstPos else {
            throw SceneFormatError.invalid("the LZ4 match offset \(offset) is outside the existing output")
        }
        var matchLength = token & 15
        if matchLength == 15 {
            var extra: Int
            repeat {
                extra = try readByte()
                matchLength += extra
            } while extra == 255
        }
        matchLength += 4
        guard matchLength <= size - dstPos else {
            throw SceneFormatError.truncated("the LZ4 match overruns the output")
        }
        var matchPos = dstPos - offset
        // Byte-by-byte copy: matches may overlap (offset < length).
        for _ in 0..<matchLength {
            dst[dstPos] = dst[matchPos]
            dstPos += 1
            matchPos += 1
        }
    }
    guard srcPos <= srcCount, dstPos == size else {
        throw SceneFormatError.truncated("the LZ4 block does not decode to the announced size")
    }
}

// MARK: - .tex decoder

public enum TexDecoder {
    public static let maxDimension = 16_384
    static let maxImages = 8
    static let maxMipmaps = 16
    static let maxMipBytes = 512 * 1024 * 1024
    static let maxTotalBytes = 1 * 1024 * 1024 * 1024

    /// Parses a complete `.tex` file. Counts and sizes are range checked (hostile input must not crash or allocate
    /// gigabytes). Only the FIRST image is exposed (spec 5.2); an animated texture (MP4 container or
    /// `isVideoTexture`) yields a `payload` of `.video` without mip data.
    public static func decode(_ data: Data) throws -> TexImage {
        var r = DataReader(data)
        let scanned = try scanHeader(&r)

        if scanned.isVideoTexture {
            return TexImage(textureWidth: scanned.textureWidth, textureHeight: scanned.textureHeight,
                            imageWidth: scanned.imageWidth, imageHeight: scanned.imageHeight,
                            flags: scanned.flags, payload: .video(fileExtension: "mp4"), mipmaps: [],
                            frames: [], containerMagic: scanned.containerMagic)
        }

        for imageIndex in 0..<scanned.imageCount {
            guard let mipCount = r.readInt32(), mipCount >= 1, mipCount <= maxMipmaps else {
                throw SceneFormatError.invalid("image \(imageIndex): mipmapCount is outside 1...\(maxMipmaps)")
            }
            if imageIndex > 0 {
                try skipMips(&r, mipCount: Int(mipCount), containerVersion: scanned.containerVersion,
                             isMP4: scanned.isMP4)
                continue
            }

            var mips: [TexMipmap] = []
            var total = 0
            for mipIndex in 0..<mipCount {
                if scanned.isMP4 { try readMP4Prefix(&r) }
                guard let width32 = r.readInt32(), isValidDimension(width32),
                      let height32 = r.readInt32(), isValidDimension(height32) else {
                    throw SceneFormatError.invalid("mip \(mipIndex): a size field is out of range")
                }
                let width = Int(width32)
                let height = Int(height32)
                var compressed = false
                var decompressedSize = 0
                if scanned.containerVersion >= 2 {
                    guard let isLZ4 = r.readInt32(), isLZ4 == 0 || isLZ4 == 1,
                          let declaredSize = r.readInt32(), declaredSize >= 0, declaredSize <= maxMipBytes else {
                        throw SceneFormatError.invalid("mip \(mipIndex): the LZ4 fields are out of range")
                    }
                    compressed = isLZ4 == 1
                    decompressedSize = Int(declaredSize)
                }
                guard let byteCount32 = r.readInt32(), byteCount32 >= 0, byteCount32 <= maxMipBytes,
                      Int(byteCount32) <= r.remaining else {
                    throw SceneFormatError.truncated("the data of mip \(mipIndex) is cut off")
                }
                let byteCount = Int(byteCount32)
                var bytes = data.subdata(in: r.position..<(r.position + byteCount))
                r.position += byteCount

                switch scanned.payload {
                case .pixels(let format):
                    let required = requiredBytes(width: width, height: height, format: format)
                    if compressed {
                        bytes = try LZ4.decompress(bytes, decompressedSize: decompressedSize)
                        guard decompressedSize >= required else {
                            throw SceneFormatError.invalid(
                                "mip \(mipIndex): the decompressed data is too small for \(width)x\(height)")
                        }
                        if bytes.count > required { bytes = bytes.prefix(required) }
                    } else {
                        guard byteCount >= required else {
                            throw SceneFormatError.invalid(
                                "mip \(mipIndex): \(byteCount) bytes cannot hold \(width)x\(height)")
                        }
                    }
                case .image:
                    if compressed {
                        bytes = try LZ4.decompress(bytes, decompressedSize: decompressedSize)
                    }
                    guard !bytes.isEmpty else { throw SceneFormatError.invalid("mip \(mipIndex): empty") }
                case .video:
                    break
                }
                total += bytes.count
                guard total <= maxTotalBytes else {
                    throw SceneFormatError.invalid("the texture is bigger than \(maxTotalBytes) bytes")
                }
                mips.append(TexMipmap(width: width, height: height, data: bytes))
            }

            var frames: [TexFrame] = []
            if scanned.flags.contains(.isGif) {
                frames = try readFrames(data, position: r.position)
            }
            return TexImage(textureWidth: scanned.textureWidth, textureHeight: scanned.textureHeight,
                            imageWidth: scanned.imageWidth, imageHeight: scanned.imageHeight,
                            flags: scanned.flags, payload: scanned.payload, mipmaps: mips, frames: frames,
                            containerMagic: scanned.containerMagic)
        }
        throw SceneFormatError.truncated("no image data")
    }

    /// Sizes, flags and the payload KIND of a `.tex` without reading the mip data (the parser needs the picture
    /// size for `sourceSize`, the analyzer needs to know whether the pixels exist at all).
    public static func header(for data: Data) throws -> (textureWidth: Int, textureHeight: Int,
                                                         imageWidth: Int, imageHeight: Int, flags: TexFlags,
                                                         payload: TexPayload) {
        var r = DataReader(data)
        let scanned = try scanHeader(&r)
        return (scanned.textureWidth, scanned.textureHeight, scanned.imageWidth, scanned.imageHeight,
                scanned.flags, scanned.payload)
    }

    // MARK: header scanning (shared by decode and header)

    private struct HeaderScan {
        var textureWidth: Int
        var textureHeight: Int
        var imageWidth: Int
        var imageHeight: Int
        var flags: TexFlags
        var payload: TexPayload
        var containerVersion: Int
        var containerMagic: String
        var imageCount: Int
        var isMP4: Bool
        var isVideoTexture: Bool
    }

    private static func scanHeader(_ r: inout DataReader) throws -> HeaderScan {
        let magic1 = try readCString(&r, max: 16)
        let magic2 = try readCString(&r, max: 16)
        guard magic1.hasPrefix("TEXV"), magic2.hasPrefix("TEXI") else {
            throw SceneFormatError.badMagic("a .tex signature is missing")
        }

        guard let formatRaw = r.readInt32(), formatRaw >= 0 else {
            throw SceneFormatError.truncated("the .tex format field is missing")
        }
        guard let flagsRaw = r.readInt32(), flagsRaw >= 0 else {
            throw SceneFormatError.truncated("the .tex flags field is missing")
        }
        let flags = TexFlags(rawValue: Int(flagsRaw))

        guard let textureWidth = r.readInt32(), isValidDimension(textureWidth),
              let textureHeight = r.readInt32(), isValidDimension(textureHeight),
              let imageWidth = r.readInt32(), isValidDimension(imageWidth),
              let imageHeight = r.readInt32(), isValidDimension(imageHeight),
              r.readInt32() != nil else {   // unknown / reserved field
            throw SceneFormatError.invalid("a .tex size field is out of range")
        }

        let containerMagic = try readCString(&r, max: 16)
        guard containerMagic.hasPrefix("TEXB") else {
            throw SceneFormatError.badMagic("the .tex image container magic is missing")
        }
        let containerVersion = Int(containerMagic.dropFirst("TEXB".count)) ?? 0
        guard containerVersion >= 1, containerVersion <= 4 else {
            throw SceneFormatError.badMagic("unknown .tex container version \(containerMagic)")
        }
        guard let imageCount32 = r.readInt32() else {
            throw SceneFormatError.truncated("the image count is missing")
        }
        guard Int(imageCount32) >= 1, Int(imageCount32) <= maxImages else {
            throw SceneFormatError.invalid("imageCount \(imageCount32) is outside 1...\(maxImages)")
        }
        let imageCount = Int(imageCount32)

        var imageFormat = -1
        var isVideoMp4 = 0
        if containerVersion >= 3 {
            guard let declared = r.readInt32() else {
                throw SceneFormatError.truncated("the image format field is missing")
            }
            imageFormat = Int(declared)
            if containerVersion >= 4 {
                guard let video = r.readInt32(), video >= 0, video <= 1 else {
                    throw SceneFormatError.invalid("isVideoMp4 is not 0 or 1")
                }
                isVideoMp4 = Int(video)
            }
        }

        let isVideoTexture = flags.contains(.isVideoTexture)
            || (imageFormat == -1 && isVideoMp4 == 1) || imageFormat == 35
        let payload: TexPayload
        if isVideoTexture {
            payload = .video(fileExtension: "mp4")
        } else if imageFormat >= 0 {
            payload = .image(fileExtension: extOfFreeImageFormat(Int(imageFormat)))
        } else {
            payload = .pixels(pixelFormatFor(formatRaw))
        }

        return HeaderScan(textureWidth: Int(textureWidth), textureHeight: Int(textureHeight),
                          imageWidth: Int(imageWidth), imageHeight: Int(imageHeight), flags: flags, payload: payload,
                          containerVersion: containerVersion, containerMagic: containerMagic,
                          imageCount: imageCount, isMP4: imageFormat == 35, isVideoTexture: isVideoTexture)
    }

    static func isValidDimension(_ value: Int32) -> Bool { value >= 0 && value <= maxDimension }

    static func requiredBytes(width: Int, height: Int, format: TexPixelFormat) -> Int {
        let blocks = max(1, (width + 3) / 4) * max(1, (height + 3) / 4)
        switch format {
        case .rgba8888: return width * height * 4
        case .rg88: return width * height * 2
        case .r8: return width * height
        case .dxt1: return blocks * 8
        case .dxt3, .dxt5: return blocks * 16
        }
    }

    static func pixelFormatFor(_ formatRaw: Int32) -> TexPixelFormat {
        switch formatRaw {
        case 0: return .rgba8888
        case 4: return .dxt5
        case 6: return .dxt3
        case 7: return .dxt1
        case 8: return .rg88
        case 9: return .r8
        default: return .rgba8888    // unknown value: assume the common case
        }
    }

    /// FreeImage format ids (RePKG table).
    static func extOfFreeImageFormat(_ id: Int) -> String {
        switch id {
        case 0: return "bmp"
        case 2: return "jpg"
        case 13: return "png"
        case 17: return "tga"
        case 18: return "tif"
        case 24: return "dds"
        case 25: return "gif"
        case 35: return "mp4"
        default: return "png"      // unknown id: most Workshop textures are PNG or JPEG; the renderer retries
        }
    }

    // MARK: helpers

    private static func readCString(_ r: inout DataReader, max: Int) throws -> String {
        var bytes: [UInt8] = []
        while true {
            guard let value = r.readSingleByte() else { throw SceneFormatError.truncated("the file ends in a string") }
            if value == 0 { break }
            bytes.append(UInt8(value))
            if bytes.count > max { throw SceneFormatError.badMagic("a string field is too long") }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func readMP4Prefix(_ r: inout DataReader) throws {
        guard let one = r.readInt32(), one == 1, let two = r.readInt32(), two == 2 else {
            throw SceneFormatError.invalid("the MP4 mip prefix is not (1, 2)")
        }
        let condition = try readCString(&r, max: 4096)
        _ = condition
        guard let closing = r.readInt32(), closing == 1 else {
            throw SceneFormatError.invalid("the MP4 mip prefix does not end with 1")
        }
    }

    private static func skipMips(_ r: inout DataReader, mipCount: Int, containerVersion: Int, isMP4: Bool) throws {
        for index in 0..<mipCount {
            if isMP4 { try readMP4Prefix(&r) }
            guard let width = r.readInt32(), isValidDimension(width),
                  let height = r.readInt32(), isValidDimension(height) else {
                throw SceneFormatError.invalid("image mip \(index): a size field is out of range")
            }
            var byteCount = 0
            if containerVersion >= 2 {
                guard let isLZ4 = r.readInt32(), isLZ4 == 0 || isLZ4 == 1,
                      let decompressed = r.readInt32(), decompressed >= 0, decompressed <= maxMipBytes,
                      let bytes = r.readInt32(), bytes >= 0, bytes <= maxMipBytes else {
                    throw SceneFormatError.invalid("image mip \(index): the LZ4 fields are out of range")
                }
                byteCount = Int(bytes)
            } else {
                guard let bytes = r.readInt32(), bytes >= 0, bytes <= maxMipBytes else {
                    throw SceneFormatError.invalid("image mip \(index): the byte count is out of range")
                }
                byteCount = Int(bytes)
            }
            guard byteCount <= r.remaining else { throw SceneFormatError.truncated("image mip \(index) is cut off") }
            r.position += byteCount
        }
    }

    /// Frame table (TEXS...) of a sprite sheet. Only frame 0 is kept (M0 shows one frame).
    static func readFrames(_ data: Data, position: Int) throws -> [TexFrame] {
        var r = DataReader(data)
        r.position = position
        guard position <= data.count else { throw SceneFormatError.truncated("the frame table is missing") }
        let magic = try readCString(&r, max: 16)
        guard magic.hasPrefix("TEXS") else { return [] }
        guard let frameCount = r.readInt32(), frameCount >= 0, frameCount <= 4096 else {
            throw SceneFormatError.invalid("frameCount is out of range")
        }
        if magic == "TEXS0003" {
            guard r.readInt32() != nil, r.readInt32() != nil else {
                throw SceneFormatError.truncated("the gif size is missing")
            }
        }
        guard let imageId = r.readInt32(), imageId >= 0 else { throw SceneFormatError.truncated("frame 0") }
        let seconds: Double
        if magic == "TEXS0001" {
            guard let timeRaw = r.readInt32() else { throw SceneFormatError.truncated("frame 0 is truncated") }
            seconds = Double(Float(bitPattern: UInt32(truncatingIfNeeded: timeRaw)))
        } else {
            guard let time = r.readFloat32() else { throw SceneFormatError.truncated("frame 0 is truncated") }
            seconds = Double(time)
        }
        let rect: (Double, Double, Double, Double)
        if magic == "TEXS0001" {
            guard let x = r.readInt32(), let y = r.readInt32(), let width = r.readInt32(),
                  r.readInt32() != nil, r.readInt32() != nil, let height = r.readInt32() else {
                throw SceneFormatError.truncated("frame 0 is truncated")
            }
            rect = (Double(x), Double(y), Double(width), Double(height))
        } else {
            guard let x = r.readFloat32(), let y = r.readFloat32(), let width = r.readFloat32(),
                  r.readFloat32() != nil, r.readFloat32() != nil, let height = r.readFloat32() else {
                throw SceneFormatError.truncated("frame 0 is truncated")
            }
            rect = (Double(x), Double(y), Double(width), Double(height))
        }
        return [TexFrame(imageIndex: Int(imageId), seconds: seconds, x: rect.0, y: rect.1,
                         width: rect.2, height: rect.3)]
    }
}
