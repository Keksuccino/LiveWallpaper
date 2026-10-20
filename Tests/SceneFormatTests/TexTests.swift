import XCTest
@testable import SceneFormat

final class TexTests: XCTestCase {
    func testPixelsRaw() throws {
        var fixture = TexFixture()
        fixture.flags = TexFlags.clampUVs.rawValue
        let data = fixture.build()
        let image = try TexDecoder.decode(data)
        XCTAssertEqual(image.containerMagic, "TEXB0002")
        XCTAssertEqual(image.flags, [.clampUVs])
        XCTAssertEqual(image.payload, .pixels(.rgba8888))
        XCTAssertEqual(image.textureWidth, 4)
        XCTAssertEqual(image.mipmaps.count, 2)
        XCTAssertEqual(image.mipmaps[0].width, 2)
        XCTAssertEqual(image.mipmaps[0].height, 2)
        XCTAssertEqual(image.mipmaps[0].data, Data(repeating: 16, count: 16))
        XCTAssertEqual(image.mipmaps[1].width, 1)
        XCTAssertEqual(image.mipmaps[1].data, Data(repeating: 16, count: 4))
        XCTAssertTrue(image.frames.isEmpty)
    }

    func testPixelsLZ4() throws {
        var fixture = TexFixture()
        fixture.lz4 = true
        let image = try TexDecoder.decode(fixture.build())
        XCTAssertEqual(image.payload, .pixels(.rgba8888))
        XCTAssertEqual(image.mipmaps[0].data, Data(repeating: 16, count: 16))
        XCTAssertEqual(image.mipmaps[1].data, Data(repeating: 16, count: 4))
    }

    func testHeader() throws {
        let header = try TexDecoder.header(for: smallRGBA8888())
        XCTAssertEqual(header.textureWidth, 2)
        XCTAssertEqual(header.imageWidth, 2)
        XCTAssertEqual(header.payload, .pixels(.rgba8888))
    }

    func testImagePayloadGetsFreeImageExtension() throws {
        var fixture = TexFixture()
        fixture.format = 13                     // FreeImage png id
        fixture.containerMagic = "TEXB0003"
        fixture.imageFormat = 13
        let image = try TexDecoder.decode(fixture.build())
        XCTAssertEqual(image.payload, .image(fileExtension: "png"))
    }

    func testUnknownFreeImageFormatAssumesJPG() throws {
        var fixture = TexFixture()
        fixture.containerMagic = "TEXB0003"
        fixture.imageFormat = 999               // not in the table → png (renderer retries)
        let image = try TexDecoder.decode(fixture.build())
        XCTAssertEqual(image.payload, .image(fileExtension: "png"))
    }

    func testVideoTextureViaImageFormat() throws {
        var fixture = TexFixture()
        fixture.containerMagic = "TEXB0003"
        fixture.imageFormat = 35
        let image = try TexDecoder.decode(fixture.build())
        XCTAssertEqual(image.payload, .video(fileExtension: "mp4"))
        XCTAssertTrue(image.mipmaps.isEmpty)
    }

    func testVideoTextureViaTEXB0004Flag() throws {
        var fixture = TexFixture()
        fixture.containerMagic = "TEXB0004"
        fixture.imageFormat = 0
        fixture.isVideoMp4 = 1
        let image = try TexDecoder.decode(fixture.build())
        XCTAssertEqual(image.payload, .video(fileExtension: "mp4"))
    }

    func testVideoTextureViaFlags() throws {
        var fixture = TexFixture()
        fixture.flags = 32                      // isVideoTexture flag bit
        let image = try TexDecoder.decode(fixture.build())
        XCTAssertEqual(image.payload, .video(fileExtension: "mp4"))
    }

    func testSpriteSheetFrame0() throws {
        var fixture = TexFixture()
        fixture.flags = TexFlags.isGif.rawValue
        fixture.frameTable = { framesTEXS0002() }
        let image = try TexDecoder.decode(fixture.build())
        XCTAssertEqual(image.frames.count, 1)
        XCTAssertEqual(image.frames[0].seconds, 0.5, accuracy: 0.0001)
        XCTAssertEqual(image.frames[0].x, 10, accuracy: 0.001)
        XCTAssertEqual(image.frames[0].width, 100, accuracy: 0.001)
        XCTAssertEqual(image.frames[0].height, 80, accuracy: 0.001)
    }

    func testBadMagics() {
        var fixture = TexFixture()
        let data = fixture.build()
        // the first signature and the container magic are both required
        XCTAssertThrowsError(try TexDecoder.decode(Data("garbage".utf8)))
        var swapped = data
        swapped[3] = 0x57   // TEXV -> TEWV, same length
        XCTAssertThrowsError(try TexDecoder.decode(swapped))
    }

    func testUnsignedContainer() throws {
        var fixture = TexFixture()
        fixture.containerMagic = "TEXB0009"     // beyond the supported versions 1...4
        XCTAssertThrowsError(try TexDecoder.decode(fixture.build()))
    }

    func testCutOffMipData() throws {
        let data = smallRGBA8888()
        var cut = data
        cut = cut.prefix(data.count - 3)        // the last mip is announced but incomplete
        XCTAssertThrowsError(try TexDecoder.decode(cut))
    }

    func testLZ4TruncatedMatchOffset() {
        // token announces a match (no literals) but the offset bytes are cut off: rejected, no crash
        let block = Data([0x01, 0x00])
        XCTAssertThrowsError(try LZ4.decompress(block, decompressedSize: 8))
    }

    func testLZ4TruncatedBlock() {
        // a literal run announced at the end of the block that is not present in full
        let block = Data([UInt8(1 << 4), 0xAA]) // token, one literal byte missing
        XCTAssertThrowsError(try LZ4.decompress(block, decompressedSize: 2))
    }

    func testLZ4Roundtrip() throws {
        // 16 bytes: 8 literals "AB..." then an offset-1 match for the other 8
        var literals: [UInt8] = []
        for index in 0..<8 { literals.append(UInt8(index * 17 + 1)) }
        var block = Data([UInt8((8 << 4) | 4)])  // 8 literals, match length 8
        block.append(contentsOf: literals)
        block.append(contentsOf: [0x01, 0x00])
        let out = try LZ4.decompress(block, decompressedSize: 16)
        XCTAssertEqual(out.count, 16)
        for index in 8..<16 {
            XCTAssertEqual(out[index], out[index - 1], "the match copies byte by byte")
        }
    }

    func testLZ4SuperCompressed() throws {
        var block = Data([UInt8(4 << 4)])       // literals carry all the bytes, no match
        block.append(contentsOf: [7, 8, 9, 10])
        let out = try LZ4.decompress(block, decompressedSize: 4)
        XCTAssertEqual(out, Data([7, 8, 9, 10]))
    }
}
