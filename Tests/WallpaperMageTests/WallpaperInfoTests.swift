import XCTest
import Core
@testable import WallpaperMage

// The inspector's Info section: how a Workshop item's tags split into kind, resolution, rating and topics, and what a
// wallpaper's files say about it.
@MainActor
final class WallpaperInfoTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testTagsSplitIntoResolutionRatingAndTopics() {
        let tags = ["Scene", "Anime", "3840 x 2160", "Mature", "Landscape"]
        XCTAssertEqual(WorkshopTags.resolution(in: tags), "3840 x 2160")
        XCTAssertEqual(WorkshopTags.rating(in: tags), "Mature")
        XCTAssertEqual(WorkshopTags.topics(in: tags, kind: ItemKind.scene.rawValue), ["Anime", "Landscape"])
        XCTAssertEqual(WorkshopTags.topics(in: ["Video", "Other resolution", "Everyone"], kind: ItemKind.video.rawValue),
                       [])
        XCTAssertNil(WorkshopTags.rating(in: ["Anime"]))
    }

    func testOwnVideoMeasuresItsFile() async throws {
        let file = folder.appendingPathComponent("clip.mp4")
        try Data(count: 1234).write(to: file)
        let facts = await WallpaperFacts.load(for: VideoItem(url: file))
        XCTAssertEqual(facts.bytes, 1234)
        XCTAssertNil(facts.resolution, "not a playable video")
        XCTAssertNil(facts.duration)
    }

    func testSceneHasItsDesignSizeAndNoDuration() async {
        let item = VideoItem(path: folder.appendingPathComponent("scene.pkg").path,
                             scene: SceneInfo(designWidth: 2560, designHeight: 1440))
        let facts = await WallpaperFacts.load(for: item)
        XCTAssertEqual(facts.resolution, CGSize(width: 2560, height: 1440))
        XCTAssertNil(facts.duration)
        XCTAssertNil(facts.bytes, "the file is missing")
    }
}
