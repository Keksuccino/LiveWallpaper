import XCTest
@testable import SceneFormat

final class SceneParserTests: XCTestCase {
    // A complete scene: model + material + texture, everything inside one in-memory .pkg.
    private func scenePackage(objects: [String], general: [String: Any]? = nil,
                              camera: [String: Any] = [:], tex: Data? = nil) throws -> Data {
        let parsedObjects: [Any] = try objects.map { raw in
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as Any
        }
        var sceneDict: [String: Any] = ["objects": parsedObjects]
        sceneDict["general"] = general ?? ["orthogonalprojection": ["width": 1920, "height": 1080]]
        if !camera.isEmpty { sceneDict["camera"] = camera }
        let material: [String: Any] = [
            "passes": [["shader": "genericimage2", "blending": "additive", "textures": ["bg"]]],
        ]
        let model: [String: Any] = ["width": 512, "height": 256, "material": "materials/bg.json"]
        return pkgBytes(entries: [
            ("scene.json", jsonBytes(sceneDict)),
            ("models/bg.json", jsonBytes(model)),
            ("materials/bg.json", jsonBytes(material)),
            ("materials/bg.tex", tex ?? smallTex()),
        ])
    }

    private func smallTex() -> Data {
        smallRGBA8888()
    }

    private let imageObject = #"{"id": 1, "name": "bg", "origin": "100 200 0", "angles": "0 0 45", "scale": "2 2 1", "parallaxdepth": "0 1", "image": "models/bg.json"}"#

    private func parsedDocument(of pkg: Data) throws -> (SceneDocument, SceneAnalysis) {
        let archive = try PKGArchive(data: pkg)
        let document = try SceneLoader.parseDocument(sceneJSON: try archive.data(at: "scene.json"), files: archive)
        return (document, SceneAnalyzer.analyze(document: document, files: archive))
    }

    func testParseAndAnalysisFull() throws {
        let (document, analysis) = try parsedDocument(of: try scenePackage(objects: [imageObject]))

        XCTAssertEqual(document.objects.count, 1)
        let object = document.objects[0]
        // Wallpaper Engine writes y-down top-left origins; they are mirrored into design space (y up)
        XCTAssertEqual(object.origin, Vec3(100, 1080 - 200, 0))
        XCTAssertEqual(object.angles, Vec3(0, 0, 45))
        XCTAssertEqual(object.parallaxDepth, Vec2(0, 1))
        XCTAssertEqual(object.id, 1)
        XCTAssertEqual(object.name, "bg")
        guard case .image(let layer) = object.kind else { return XCTFail("not an image layer") }
        XCTAssertEqual(layer.texturePath, "materials/bg.tex")
        XCTAssertEqual(layer.materialPath, "materials/bg.json")
        XCTAssertEqual(layer.shader, "genericimage2")
        XCTAssertEqual(layer.blend, .additive)
        XCTAssertEqual(layer.sourceSize, Vec2(512, 256))

        XCTAssertEqual(analysis.support, .full)
        XCTAssertTrue(analysis.notes.isEmpty)
        XCTAssertTrue(analysis.used.contains(.imageLayers))
        XCTAssertNil(analysis.loopSeconds)   // M0 finds no period
        XCTAssertEqual(analysis.designWidth, 1920)
        XCTAssertEqual(analysis.designHeight, 1080)
    }

    func testCameraCenterMirrored() throws {
        let (document, _) = try parsedDocument(
            of: try scenePackage(objects: [imageObject], camera: ["center": "960 240"]))
        XCTAssertEqual(document.camera.center, Vec3(960, 1080 - 240, 0))
    }

    func testPreviewOnlyWhenNoObjects() throws {
        let (_, analysis) = try parsedDocument(of: try scenePackage(objects: []))
        XCTAssertEqual(analysis.support, .previewOnly)
        XCTAssertEqual(analysis.notes, ["Only the preview image is shown."])
        XCTAssertEqual(analysis.unsupported, [.noRenderableLayer])
    }

    func testUnsupportedFeaturesAndNoteOrder() throws {
        // one image + one particle + one sound + bloom: notes follow the fixed order of spec 5.5
        let (document, analysis) = try parsedDocument(of: try scenePackage(
            objects: [imageObject, #"{"id": 2, "particle": "particles/foo.json"}"#,
                      #"{"id": 3, "sound": "audio/bg.mp3"}"#],
            general: ["bloom": true,
                      "orthogonalprojection": ["width": 1920, "height": 1080]]))
        _ = document
        XCTAssertEqual(analysis.support, .partial)
        XCTAssertEqual(analysis.unsupported, [.particles, .sound, .bloomOrHDR])
        XCTAssertEqual(analysis.notes, [
            "Particles are not supported yet.",
            "Sound isn’t supported yet.",
            "Glow and colour post-processing are skipped.",
        ])
    }

    func testScriptAndUserPropertyBindings() throws {
        let (_, analysis) = try parsedDocument(of: try scenePackage(objects: [
            #"{"id": 1, "image": "models/bg.json", "brightness": {"value": 1, "script": "foo.lua"},
               "color": {"value": "1 1 1", "user": "mycolor"}}"#]))
        XCTAssertTrue(analysis.notes.contains("Scripted behaviour isn’t supported yet."))
        XCTAssertTrue(analysis.notes.contains("User settings of this wallpaper aren’t supported yet."))
        XCTAssertEqual(analysis.support, .partial)
    }

    func testUndecodableTexture() throws {
        // the .tex exists but is garbage: the analyzer calls it undecodable
        let archive = try PKGArchive(data: try scenePackage(objects: [imageObject], tex: Data("junk".utf8)))
        let document = try SceneLoader.parseDocument(sceneJSON: try archive.data(at: "scene.json"), files: archive)
        let analysis = SceneAnalyzer.analyze(document: document, files: archive)
        XCTAssertEqual(analysis.support, .previewOnly)
        XCTAssertTrue(analysis.unsupported.contains(.undecodableTexture))
        XCTAssertTrue(analysis.notes.contains("Some images are missing or unreadable."))
    }

    func testMissingTextureAndSharedAssets() throws {
        // primary pkg without the .tex; the texture is expected to come from the shared assets
        let material: [String: Any] = [
            "passes": [["shader": "genericimage2", "blending": "translucent", "textures": ["bg"]]],
        ]
        let model: [String: Any] = ["width": 512, "height": 256, "material": "materials/bg.json"]
        let sceneDict: [String: Any] = [
            "objects": [try! JSONSerialization.jsonObject(with: Data(#"{"id": 1, "image": "models/bg.json"}"#.utf8))],
        ]
        let pkg = pkgBytes(entries: [
            ("scene.json", jsonBytes(sceneDict)),
            ("models/bg.json", jsonBytes(model)),
            ("materials/bg.json", jsonBytes(material)),
        ])
        let archive = try PKGArchive(data: pkg)
        let document = try SceneLoader.parseDocument(sceneJSON: try archive.data(at: "scene.json"), files: archive)
        let analysis = SceneAnalyzer.analyze(document: document, files: archive)
        XCTAssertEqual(analysis.unsupported, [.missingTexture])
        XCTAssertEqual(analysis.support, .previewOnly)
        XCTAssertTrue(analysis.needsSharedAssets)

        // with a fallback directory that has the texture: playable, but it must be shipped along (shared assets)
        let assets = tempDirectory()
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("materials"),
                                                withIntermediateDirectories: true)
        try smallTex().write(to: assets.appendingPathComponent("materials/bg.tex"))
        let layered = LayeredSource(primary: archive, fallback: DirectorySource(root: assets))
        let analysisWithAssets = SceneAnalyzer.analyze(document: document, files: layered)
        XCTAssertEqual(analysisWithAssets.support, .full)
        XCTAssertTrue(analysisWithAssets.notes.isEmpty)
        XCTAssertTrue(analysisWithAssets.needsSharedAssets, "the texture is only in the fallback")
    }

    func testParentCycleBrokenWithoutCrash() throws {
        let archive = try PKGArchive(data: try scenePackage(objects: [
            #"{"id": 1, "parent": 2}"#, #"{"id": 2, "parent": 1}"#, #"{"id": 3, "parent": 55}"#,
            imageObject,
        ]))
        let document = try SceneLoader.parseDocument(sceneJSON: try archive.data(at: "scene.json"), files: archive)
        XCTAssertEqual(document.objects.count, 4)
        // the a -> b -> a cycle is closed by dropping the link of the second object
        XCTAssertEqual(document.objects[1].parentID, nil)
    }

    func testTextureResolutionVariants() throws {
        for raw in ["bg", "bg.tex", "materials/bg.tex"] {
            let material: [String: Any] = [
                "passes": [["shader": "genericimage2", "blending": "normal", "textures": [raw]]],
            ]
            let sceneDict: [String: Any] = [
                "objects": [try! JSONSerialization.jsonObject(
                    with: Data(#"{"id": 1, "image": "models/bg.json"}"#.utf8))],
            ]
            let model: [String: Any] = ["width": 512, "height": 256, "material": "materials/bg.json"]
            let pkg = pkgBytes(entries: [
                ("scene.json", jsonBytes(sceneDict)),
                ("models/bg.json", jsonBytes(model)),
                ("materials/bg.json", jsonBytes(material)),
                ("materials/bg.tex", smallRGBA8888()),
            ])
            let archive = try PKGArchive(data: pkg)
            let document = try SceneLoader.parseDocument(
                sceneJSON: try archive.data(at: "scene.json"), files: archive)
            guard case .image(let image) = document.objects[0].kind else {
                return XCTFail("not an image layer for raw texture '\(raw)'")
            }
            XCTAssertEqual(image.texturePath, "materials/bg.tex", "candidate '\(raw)'")
            XCTAssertEqual(image.blend, .normal)
        }
    }

    func testUnknownBlendModeIsReported() throws {
        let material: [String: Any] = [
            "passes": [["shader": "genericimage2", "blending": "weirdblend", "textures": ["bg"]]],
        ]
        let sceneDict: [String: Any] = [
            "objects": [try! JSONSerialization.jsonObject(
                with: Data(#"{"id": 1, "image": "models/bg.json"}"#.utf8))],
        ]
        let pkg = pkgBytes(entries: [
            ("scene.json", jsonBytes(sceneDict)),
            ("models/bg.json",
             jsonBytes(["width": 512, "height": 256, "material": "materials/bg.json"])),
            ("materials/bg.json", jsonBytes(material)),
            ("materials/bg.tex", smallRGBA8888()),
        ])
        let archive = try PKGArchive(data: pkg)
        let document = try SceneLoader.parseDocument(sceneJSON: try archive.data(at: "scene.json"), files: archive)
        guard case .image(let layer) = document.objects[0].kind else { return XCTFail("not image") }
        XCTAssertEqual(layer.blend, .unknown)
        let analysis = SceneAnalyzer.analyze(document: document, files: archive)
        XCTAssertEqual(analysis.support, .partial)
        XCTAssertEqual(analysis.notes, ["A blend mode isn’t supported and is drawn as normal."])
    }
}

/// Kit: each call returns a fresh directory under the test temp area.
func tempDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("lw-assets-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
