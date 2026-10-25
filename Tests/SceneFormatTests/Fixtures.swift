import Foundation
@testable import SceneFormat

/// Fixture builders for the container tests. Everything is a valid little-endian byte stream built by hand so the
/// tests state exactly what the format is, and stay independent of Wallpaper Engine content.

struct DataWriter {
    private(set) var data = Data()

    mutating func int32(_ value: Int32) {
        var stored = value.littleEndian
        withUnsafeBytes(of: &stored) { data.append(contentsOf: $0) }
    }

    mutating func float32(_ value: Float) {
        int32(Int32(bitPattern: value.bitPattern))
    }

    /// Length-prefixed string (Int32 count + bytes, no terminator) — the .pkg layout (Reader.readBytes).
    mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        int32(Int32(bytes.count))
        data.append(contentsOf: bytes)
    }

    /// Null-terminated string WITHOUT a count — the .tex and TEXS layout (Reader.readCString).
    mutating func cstring(_ value: String) {
        data.append(contentsOf: value.utf8)
        data.append(contentsOf: [0x00])
    }

    mutating func bytes(_ value: Data) {
        data.append(value)
    }
}

// MARK: - .pkg

/// Builds a `.pkg`: length-prefixed magic, entry count, per entry (length-prefixed path, offset, length
/// relative to the data section), then the concatenated payload.
func pkgBytes(magic: String = "PKGV0001", entries: [(path: String, body: Data)]) -> Data {
    var writer = DataWriter()
    writer.string(magic)
    writer.int32(Int32(entries.count))
    var offset = 0
    for entry in entries {
        writer.string(entry.path)
        writer.int32(Int32(offset))
        writer.int32(Int32(entry.body.count))
        offset += entry.body.count
    }
    for entry in entries { writer.bytes(entry.body) }
    return writer.data
}

func jsonBytes(_ value: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: value)
}

// MARK: - LZ4

/// One LZ4 block that decompresses to exactly `outputCount` copies of `pixel`:
/// up to 15 bytes fit as literals alone (the decoder just runs out of output before the match);
/// larger counts use a run-length match at offset 1 that repeats the first literal.
func lz4Block(outputCount: Int, pixel: UInt8) -> Data {
    precondition(outputCount >= 1)
    precondition(outputCount % 2 == 0, "even literal and match halves")
    if outputCount <= 15 {
        var block = Data([UInt8(outputCount << 4)])
        block.append(contentsOf: repeatElement(pixel, count: outputCount))
        return block    // out full after the literals: no match is read
    }
    let half = outputCount / 2
    precondition(half - 4 <= 15, "match nibble range")
    var block = Data()
    block.append(UInt8((half << 4) | (half - 4)))
    block.append(contentsOf: repeatElement(pixel, count: half))
    block.append(contentsOf: [0x01, 0x00])
    return block
}

// MARK: - .tex

/// RGBA8888 texture: pixel-format payload with two mips (2x2 and 1x1) of `pixelValue` bytes each;
/// `lz4` switches the mips to the LZ4 fields. `imageFormat` (spec: FreeImage ids; -1 marks an MP4 v4 texture)
/// selects the encoded-image payload instead. `frameTable` appends a sprite-table when set.

struct TexFixture {
    var format: Int32 = 0                 // pixel format id (0 = rgba8888)
    var flags: Int32 = 0
    var textureWidth: Int = 4
    var textureHeight: Int = 4
    var imageWidth: Int = 4
    var imageHeight: Int = 4
    var containerMagic: String = "TEXB0002"
    var imageCount: Int32 = 1
    var imageFormat: Int? = nil           // TEXB0003+: FreeImage id; MP4 textures write -1
    var isVideoMp4: Int? = nil            // TEXB0004 extra field (MP4 when 1 and imageFormat is -1)
    var lz4: Bool = false
    var pixelValue: UInt8 = 16
    var frameTable: () -> Data = { Data() }

    func build() -> Data {
        var writer = DataWriter()
        writer.cstring("TEXV0005")
        writer.cstring("TEXI0001")
        writer.int32(format)
        writer.int32(flags)
        writer.int32(Int32(textureWidth))
        writer.int32(Int32(textureHeight))
        writer.int32(Int32(imageWidth))
        writer.int32(Int32(imageHeight))
        writer.int32(0)                       // reserved
        writer.cstring(containerMagic)
        writer.int32(imageCount)
        let containerVersion = Int(containerMagic.dropFirst("TEXB".count)) ?? 0
        if containerVersion >= 3, let imageFormat {
            writer.int32(Int32(imageFormat))
            if containerVersion >= 4, let isVideoMp4 {
                writer.int32(Int32(isVideoMp4))
            }
        }
        let isVideo = imageFormat == 35 || flags & 32 != 0
        if !isVideo {
            for _ in 0..<max(1, Int(imageCount)) {
                writer.int32(2)                                  // mipmap count
                for mip in 0..<2 {
                    let width = mip == 0 ? 2 : 1
                    let height = width
                    let required = width * height * 4            // decompressed rgba8888 size
                    let payload = lz4 ? lz4Block(outputCount: required, pixel: pixelValue)
                                      : Data(repeating: pixelValue, count: required)
                    writer.int32(Int32(width))
                    writer.int32(Int32(height))
                    if containerVersion >= 2 {
                        writer.int32(lz4 ? 1 : 0)
                        writer.int32(Int32(required))            // decompressedSize announcement
                        writer.int32(Int32(payload.count))       // stored byte count
                    } else {
                        writer.int32(Int32(required))
                    }
                    writer.bytes(payload)
                }
            }
        }
        let table = frameTable()
        writer.bytes(table)
        return writer.data
    }
}

/// A valid 2x2 rgba8888 texture (one 2x2 mip and one 1x1 mip of the same pixel value bytes).
func smallRGBA8888() -> Data {
    var fixture = TexFixture()
    fixture.textureWidth = 2
    fixture.textureHeight = 2
    fixture.imageWidth = 2
    fixture.imageHeight = 2
    return fixture.build()
}

// MARK: - TEXS frame tables

/// TEXS0002 sprite frame table with 1 frame (float fields everywhere except count).
func framesTEXS0002(count: Int32 = 1) -> Data {
    var writer = DataWriter()
    writer.cstring("TEXS0002")
    writer.int32(count)
    writer.int32(0)                       // image id of frame 0
    writer.float32(0.5)                   // seconds frame 0 is shown
    writer.float32(10)
    writer.float32(20)
    writer.float32(100)
    writer.float32(0)                     // don't care
    writer.float32(0)                     // don't care
    writer.float32(80)
    return writer.data
}
