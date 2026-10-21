import XCTest
import simd
@testable import SceneFormat
@testable import SceneEngine

/// Geometry of the flattened scene (SPEC3.md section 5.3): where a layer's quad lands in the world.
///
/// The checks are relative (a layer with a parent must land where it lands without one, a scaled layer must
/// grow by exactly its scale) so they do not re-implement the renderer's matrix maths.
final class SceneGeometryTests: XCTestCase {
    // MARK: fixtures

    private struct Writer {
        var data = Data()
        mutating func int32(_ value: Int32) {
            var stored = value.littleEndian
            withUnsafeBytes(of: &stored) { data.append(contentsOf: $0) }
        }
        /// Length-prefixed string (the .pkg layout).
        mutating func string(_ value: String) {
            let bytes = Array(value.utf8)
            int32(Int32(bytes.count))
            data.append(contentsOf: bytes)
        }
        /// Null-terminated string (the .tex layout).
        mutating func cstring(_ value: String) {
            data.append(contentsOf: value.utf8)
            data.append(0x00)
        }
        mutating func bytes(_ value: Data) { data.append(value) }
    }

    private func pkgBytes(entries: [(path: String, body: Data)]) -> Data {
        var writer = Writer()
        writer.string("PKGV0001")
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

    /// A 64x32 rgba8888 texture with one mip.
    private func texBytes(width: Int = 64, height: Int = 32) -> Data {
        var writer = Writer()
        writer.cstring("TEXV0005")
        writer.cstring("TEXI0001")
        writer.int32(0)                       // format: rgba8888
        writer.int32(0)                       // flags
        writer.int32(Int32(width))
        writer.int32(Int32(height))
        writer.int32(Int32(width))
        writer.int32(Int32(height))
        writer.int32(0)                       // reserved
        writer.cstring("TEXB0002")
        writer.int32(1)                       // image count
        writer.int32(1)                       // mipmap count
        writer.int32(Int32(width))
        writer.int32(Int32(height))
        writer.int32(0)                       // not LZ4
        writer.int32(Int32(width * height * 4))
        writer.int32(Int32(width * height * 4))
        writer.bytes(Data(repeating: 32, count: width * height * 4))
        return writer.data
    }

    private func jsonBytes(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value)
    }

    /// A scene in a 1920x1080 design with one image layer (and optionally a parent group).
    private func loadedScene(layer: [String: Any], group: [String: Any]? = nil) throws -> LoadedScene {
        var objects: [[String: Any]] = []
        if let group { objects.append(group) }
        objects.append(layer)
        let material: [String: Any] = [
            "passes": [["shader": "genericimage2", "blending": "normal", "textures": ["materials/bg.tex"]]],
        ]
        let model: [String: Any] = ["material": "materials/bg.json"]
        let scene: [String: Any] = [
            "objects": objects,
            "general": ["orthogonalprojection": ["width": 1920, "height": 1080]],
        ]
        let archive = try PKGArchive(data: pkgBytes(entries: [
            ("scene.json", jsonBytes(scene)),
            ("models/bg.json", jsonBytes(model)),
            ("materials/bg.json", jsonBytes(material)),
            ("materials/bg.tex", texBytes()),
        ]))
        let document = try SceneLoader.parseDocument(sceneJSON: try archive.data(at: "scene.json"), files: archive)
        let analysis = SceneAnalyzer.analyze(document: document, files: archive)
        return LoadedScene(files: archive, document: document, analysis: analysis)
    }

    private func imageLayer(id: Int = 1, origin: String = "960 540 0", scale: String = "1 1 1",
                            parent: Int? = nil) -> [String: Any] {
        var object: [String: Any] = [
            "id": id, "name": "layer", "origin": origin, "angles": "0 0 0", "scale": scale,
            "image": "models/bg.json",
        ]
        if let parent { object["parent"] = parent }
        return object
    }

    /// The layer's quad in world space (y up, the design's bottom left is the origin).
    private func worldRect(of layer: SceneRenderer.PreparedLayer) -> (x: ClosedRange<Float>, y: ClosedRange<Float>) {
        let corners: [SIMD4<Float>] = [
            SIMD4(-1, -1, 0, 1), SIMD4(1, -1, 0, 1), SIMD4(1, 1, 0, 1), SIMD4(-1, 1, 0, 1),
        ].map { layer.model * $0 }
        let xs = corners.map { $0.x / $0.w }, ys = corners.map { $0.y / $0.w }
        return (xs.min()!...xs.max()!, ys.min()!...ys.max()!)
    }

    private func flattened(_ scene: LoadedScene) -> [SceneRenderer.PreparedLayer] {
        SceneRenderer.flatten(scene: scene, files: scene.files)
    }

    // MARK: tests

    func testLayerAtDesignCenterIsCenteredOnIt() throws {
        // The file's origin is y down; the design's centre is the same point in both spaces.
        let layers = flattened(try loadedScene(layer: imageLayer(origin: "960 540 0")))
        let rect = worldRect(of: layers[0])
        XCTAssertEqual(rect.x.lowerBound, 960 - 32, accuracy: 0.5)
        XCTAssertEqual(rect.x.upperBound, 960 + 32, accuracy: 0.5)
        XCTAssertEqual(rect.y.lowerBound, 540 - 16, accuracy: 0.5)
        XCTAssertEqual(rect.y.upperBound, 540 + 16, accuracy: 0.5)
    }

    func testParentGroupAtFileOriginDoesNotMoveItsChild() throws {
        // The group sits at the file's top left, so it must not shift the child. Composing the chain in the
        // file's y-down space (and mirroring once) keeps the child where it is; mirroring every ancestor's
        // translation instead would add the design height per level and push the child off the design.
        let withoutParent = flattened(try loadedScene(layer: imageLayer(origin: "960 540 0")))
        let withParent = flattened(try loadedScene(
            layer: imageLayer(origin: "960 540 0", parent: 7),
            group: ["id": 7, "name": "root", "origin": "0 0 0", "angles": "0 0 0", "scale": "1 1 1"]))
        XCTAssertEqual(withParent.count, 1)
        let a = worldRect(of: withoutParent[0]), b = worldRect(of: withParent[0])
        XCTAssertEqual(a.x.lowerBound, b.x.lowerBound, accuracy: 0.001)
        XCTAssertEqual(a.x.upperBound, b.x.upperBound, accuracy: 0.001)
        XCTAssertEqual(a.y.lowerBound, b.y.lowerBound, accuracy: 0.001)
        XCTAssertEqual(a.y.upperBound, b.y.upperBound, accuracy: 0.001)
    }

    func testScaleIsAppliedOnce() throws {
        // A layer of 64x32 at scale 2 is 128x64 in the world: the size must not be scaled twice.
        let plain = flattened(try loadedScene(layer: imageLayer(origin: "960 540 0")))
        let scaled = flattened(try loadedScene(layer: imageLayer(origin: "960 540 0", scale: "2 2 1")))
        let a = worldRect(of: plain[0]), b = worldRect(of: scaled[0])
        XCTAssertEqual(b.x.upperBound - b.x.lowerBound, (a.x.upperBound - a.x.lowerBound) * 2, accuracy: 0.001)
        XCTAssertEqual(b.y.upperBound - b.y.lowerBound, (a.y.upperBound - a.y.lowerBound) * 2, accuracy: 0.001)
        XCTAssertEqual((b.x.lowerBound + b.x.upperBound) / 2, 960, accuracy: 0.5)
    }
}
