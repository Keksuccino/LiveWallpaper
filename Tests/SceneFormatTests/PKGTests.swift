import XCTest
@testable import SceneFormat

final class PKGTests: XCTestCase {
    func testRoundtripAndLookup() throws {
        let data = pkgBytes(entries: [
            ("scene.json", Data("{\"v\":1}".utf8)),
            ("materials/bg.tex", Data([1, 2, 3, 4])),
        ])
        let archive = try PKGArchive(data: data)
        XCTAssertEqual(archive.magic, "PKGV0001")
        XCTAssertEqual(archive.entries.count, 2)
        XCTAssertEqual(try archive.data(at: "materials/bg.tex"), Data([1, 2, 3, 4]))
        // case-insensitive, no leading slash
        XCTAssertEqual(try archive.data(at: "/SCENE.JSON"), Data("{\"v\":1}".utf8))
        XCTAssertTrue(archive.fileExists("Materials/BG.TEX"))
        XCTAssertFalse(archive.fileExists("nope"))
        XCTAssertEqual(archive.allPaths().sorted(), ["materials/bg.tex", "scene.json"])
    }

    func testDuplicatePathsLastWins() throws {
        let data = pkgBytes(entries: [
            ("scene.json", Data("first".utf8)),
            ("scene.json", Data("second".utf8)),
        ])
        let archive = try PKGArchive(data: data)
        // allPaths lists a path once, the last entry wins
        XCTAssertEqual(archive.allPaths(), ["scene.json"])
        XCTAssertEqual(try archive.data(at: "scene.json"), Data("second".utf8))
    }

    func testWrongMagic() {
        XCTAssertThrowsError(try PKGArchive(data: pkgBytes(magic: "WATER", entries: [])))
    }

    func testTooManyEntries() {
        // a count of 100001 etc is rejected before anything is read
        var w = DataWriter()
        w.string("PKGV0001")
        w.int32(100_001)
        XCTAssertThrowsError(try PKGArchive(data: w.data))
    }

    func testEntryOutsideDataSection() {
        // an entry whose offset exceeds the data section is rejected
        let writer = { () -> Data in
            var w = DataWriter()
            w.string("PKGV0001")
            w.int32(1)
            w.string("scene.json")
            w.int32(9999)
            w.int32(4)
            w.bytes(Data("body".utf8))
            return w.data
        }()
        XCTAssertThrowsError(try PKGArchive(data: writer))
    }

    func testNegativeOffset() {
        var w = DataWriter()
        w.string("PKGV0001")
        w.int32(1)
        w.string("scene.json")
        w.int32(-1)
        w.int32(4)
        w.bytes(Data("body".utf8))
        XCTAssertThrowsError(try PKGArchive(data: w.data))
    }

    func testEmptyPath() {
        var w = DataWriter()
        w.string("PKGV0001")
        w.int32(1)
        w.string("")
        w.int32(0)
        w.int32(4)
        w.bytes(Data("body".utf8))
        XCTAssertThrowsError(try PKGArchive(data: w.data))
    }

    func testCutOffEntryTable() {
        // one entry announced, but cut off before the data
        var w = DataWriter()
        w.string("PKGV0001")
        w.int32(1)
        w.string("scene.json")
        w.int32(0)
        w.int32(4)
        w.bytes(Data("bo".utf8))  // 2 bytes short including entry payloads
        XCTAssertThrowsError(try PKGArchive(data: w.data))
    }

    func testDirectorySource() throws {
        let folder = urlForTemporary()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("materials"),
                                                withIntermediateDirectories: true)
        try Data("tex".utf8).write(to: folder.appendingPathComponent("materials/bg.tex"))
        try Data("{\"v\":1}".utf8).write(to: folder.appendingPathComponent("SCENE.JSON"))
        let source = DirectorySource(root: folder)
        XCTAssertTrue(source.fileExists("materials/bg.tex"))
        XCTAssertTrue(source.fileExists("scene.json"))
        XCTAssertEqual(try source.data(at: "SCENE.JSON"), Data("{\"v\":1}".utf8))
        XCTAssertEqual(Set(source.allPaths()), Set(["materials/bg.tex", "scene.json"]))
    }
}

// Kit: each test gets a directory under the test temp area.
var counter = 0
func urlForTemporary() -> URL {
    counter += 1
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lwtest-\(counter)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
