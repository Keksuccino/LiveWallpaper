import XCTest
@testable import SceneFormat

final class SceneParserTests: XCTestCase {
    /// The analysis only checks that a texture exists, never reads it.
    private let texture = Data("tex".utf8)

    private let imageObject = #"{"id": 1, "name": "bg", "image": "models/bg.json"}"#

    /// The files of a scene with one model and material, and the material's texture unless `withTexture` is false.
    private func sceneFiles(objects: [String], general: [String: Any]? = nil,
                            withTexture: Bool = true) throws -> [(path: String, body: Data)] {
        let parsedObjects: [Any] = try objects.map { raw in
            try JSONSerialization.jsonObject(with: Data(raw.utf8)) as Any
        }
        var sceneDict: [String: Any] = ["objects": parsedObjects]
        sceneDict["general"] = general ?? ["orthogonalprojection": ["width": 2560, "height": 1440]]
        let material: [String: Any] = [
            "passes": [["shader": "genericimage2", "blending": "translucent", "textures": ["bg"]]],
        ]
        let model: [String: Any] = ["width": 512, "height": 256, "material": "materials/bg.json"]
        var files: [(path: String, body: Data)] = [
            ("scene.json", jsonBytes(sceneDict)),
            ("models/bg.json", jsonBytes(model)),
            ("materials/bg.json", jsonBytes(material)),
        ]
        if withTexture { files.append(("materials/bg.tex", texture)) }
        return files
    }

    private func parsedDocument(of entries: [(path: String, body: Data)],
                                sharedAssets: URL? = nil) throws -> (SceneDocument, SceneAnalysis) {
        let archive = try PKGArchive(data: pkgBytes(entries: entries))
        let files = LayeredSource(primary: archive, fallback: sharedAssets.map { DirectorySource(root: $0) })
        let document = try SceneLoader.parseDocument(sceneJSON: try archive.data(at: "scene.json"), files: files)
        return (document, SceneAnalyzer.analyze(document: document, files: files))
    }

    /// A shared-assets folder that has the scene's texture.
    private func sharedAssetsWithTexture() throws -> URL {
        let assets = tempDirectory()
        try FileManager.default.createDirectory(at: assets.appendingPathComponent("materials"),
                                                withIntermediateDirectories: true)
        try texture.write(to: assets.appendingPathComponent("materials/bg.tex"))
        return assets
    }

    func testParseAndAnalysis() throws {
        let (document, analysis) = try parsedDocument(of: try sceneFiles(objects: [imageObject]))
        XCTAssertEqual(document.imageLayers, [ImageLayer(shown: true, texturePath: "materials/bg.tex")])
        XCTAssertEqual(analysis, SceneAnalysis(designWidth: 2560, designHeight: 1440, needsSharedAssets: false))
    }

    func testDesignSizeDefaultsWithoutProjection() throws {
        let (_, analysis) = try parsedDocument(of: try sceneFiles(objects: [imageObject], general: [:]))
        XCTAssertEqual(analysis.designWidth, 1920)
        XCTAssertEqual(analysis.designHeight, 1080)
    }

    func testOnlyImageObjectsAreLayers() throws {
        let (document, _) = try parsedDocument(of: try sceneFiles(objects: [
            imageObject, #"{"id": 2, "particle": "particles/foo.json"}"#, #"{"id": 3, "sound": "audio/bg.mp3"}"#,
            #"{"id": 4, "name": "group"}"#,
        ]))
        XCTAssertEqual(document.imageLayers.count, 1)
    }

    func testHiddenTransparentAndBoundValues() throws {
        let (document, _) = try parsedDocument(of: try sceneFiles(objects: [
            #"{"id": 1, "image": "models/bg.json", "visible": false}"#,
            #"{"id": 2, "image": "models/bg.json", "alpha": 0}"#,
            #"{"id": 3, "image": "models/bg.json", "visible": {"value": false, "user": "showbg"}}"#,
            #"{"id": 4, "image": "models/bg.json", "alpha": {"value": 0.5, "script": "foo.lua"}}"#,
        ]))
        XCTAssertEqual(document.imageLayers.map(\.shown), [false, false, false, true])
    }

    func testMissingTextureAndSharedAssets() throws {
        // the package without the .tex; the texture is expected to come from the shared assets
        let entries = try sceneFiles(objects: [imageObject], withTexture: false)
        let (document, analysis) = try parsedDocument(of: entries)
        XCTAssertNil(document.imageLayers[0].texturePath)
        XCTAssertTrue(analysis.needsSharedAssets, "the texture is not in the package")

        // with shared assets that have the texture: the parse sees it through them (like SceneLoader.analyze), so
        // the analyzer still flags the dependency
        let (documentWithAssets, analysisWithAssets) = try parsedDocument(of: entries,
                                                                         sharedAssets: try sharedAssetsWithTexture())
        XCTAssertEqual(documentWithAssets.imageLayers[0].texturePath, "materials/bg.tex")
        XCTAssertTrue(analysisWithAssets.needsSharedAssets, "the texture is only in the shared assets")
    }

    func testHiddenLayerCountsOnlyWhenItsTextureIsInTheSharedAssets() throws {
        let entries = try sceneFiles(objects: [#"{"id": 1, "image": "models/bg.json", "visible": false}"#],
                                     withTexture: false)
        XCTAssertFalse(try parsedDocument(of: entries).1.needsSharedAssets, "the texture is nowhere")
        XCTAssertTrue(try parsedDocument(of: entries, sharedAssets: try sharedAssetsWithTexture()).1.needsSharedAssets)
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
            let (document, _) = try parsedDocument(of: [
                ("scene.json", jsonBytes(sceneDict)),
                ("models/bg.json", jsonBytes(model)),
                ("materials/bg.json", jsonBytes(material)),
                ("materials/bg.tex", texture),
            ])
            XCTAssertEqual(document.imageLayers.first?.texturePath, "materials/bg.tex", "candidate '\(raw)'")
        }
    }

    func testAnalyzesAPackageAndAFolder() throws {
        let entries = try sceneFiles(objects: [imageObject])
        let expected = SceneAnalysis(designWidth: 2560, designHeight: 1440, needsSharedAssets: false)

        let folder = tempDirectory()
        let package = folder.appendingPathComponent("scene.pkg")
        try pkgBytes(entries: entries).write(to: package)
        XCTAssertEqual(try SceneLoader.analyze(packageAt: package, sharedAssets: nil), expected)

        let loose = tempDirectory()
        for entry in entries {
            let url = loose.appendingPathComponent(entry.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try entry.body.write(to: url)
        }
        XCTAssertEqual(try SceneLoader.analyze(directory: loose, sharedAssets: nil), expected)
    }

    func testUnreadableSceneJSONThrows() {
        let archive = try! PKGArchive(data: pkgBytes(entries: []))
        XCTAssertThrowsError(try SceneLoader.parseDocument(sceneJSON: Data("not json".utf8), files: archive))
        XCTAssertThrowsError(try SceneLoader.parseDocument(sceneJSON: Data(#"{"general": {}}"#.utf8), files: archive),
                             "no object list")
    }
}

/// Kit: each call returns a fresh directory under the test temp area.
func tempDirectory() -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("wm-assets-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
