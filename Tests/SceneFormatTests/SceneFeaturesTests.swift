import XCTest
@testable import SceneFormat

final class SceneFeaturesTests: XCTestCase {
    private func features(_ json: String) throws -> SceneFeatures {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        return SceneFeatures(sceneJSON: root)
    }

    func testA2DSceneWithSoundAndParallax() throws {
        let f = try features("""
            {"general": {"orthogonalprojection": {"width": 1920, "height": 1080},
                         "cameraparallax": true, "cameraparallaxmouseinfluence": 0.5},
             "objects": [{"image": "models/a.json"}, {"sound": ["sounds/a.mp3"]}]}
            """)
        XCTAssertEqual(f, SceneFeatures(orthographic: true, sound: true, parallax: true))
    }

    func testParallaxNeedsALiteralSwitchAndAnInfluence() throws {
        let bound = try features("""
            {"general": {"cameraparallax": {"user": "p", "value": true}, "cameraparallaxmouseinfluence": 1}}
            """)
        XCTAssertFalse(bound.parallax)
        let noInfluence = try features(#"{"general": {"cameraparallax": true}}"#)
        XCTAssertFalse(noInfluence.parallax)
        let zero = try features(#"{"general": {"cameraparallax": true, "cameraparallaxmouseinfluence": 0}}"#)
        XCTAssertFalse(zero.parallax)
    }

    func testA3DSceneAndSilentObjects() throws {
        let f = try features("""
            {"general": {"orthogonalprojection": null},
             "objects": [{"sound": []}, {"model": "models/m.mdl", "sound": ["sounds/a.mp3"]}]}
            """)
        XCTAssertEqual(f, SceneFeatures(orthographic: false, sound: false, parallax: false))
    }

    func testAPackageIsRead() throws {
        let scene = Data(#"{"general": {"orthogonalprojection": {"width": 2, "height": 2}}, "objects": []}"#.utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("features-\(UUID()).pkg")
        try pkgBytes(entries: [("scene.json", scene)]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(SceneFeatures.read(scenePath: url), SceneFeatures(orthographic: true))
        XCTAssertNil(SceneFeatures.read(scenePath: url.appendingPathExtension("missing")))
    }
}
