import XCTest
import Core
@testable import WallpaperMage

// What Home's library lists: the playlists, then the wallpapers, without the kinds its filter buttons hide and
// without what the search does not match.
final class LibraryFilterTests: XCTestCase {
    private let workshopVideo = VideoItem(path: "/v/ocean.mp4", title: "Ocean", author: "Nami", workshopID: "1")
    private let ownVideo = VideoItem(path: "/v/forest.mov")
    private let scene = VideoItem(path: "/s/scene.pkg", title: "City", workshopID: "2",
                                  scene: SceneInfo(support: .full))
    private lazy var playlist = Playlist(name: "Evening", items: [scene.id, ownVideo.id])

    private func library(search: String = "", hiding hidden: Set<LibraryKind> = []) -> [LibraryEntry] {
        LibraryEntry.library(videos: [workshopVideo, ownVideo, scene], playlists: [playlist], search: search,
                             hiding: hidden)
    }

    func testEverythingShowsByDefaultWithPlaylistsFirst() {
        XCTAssertEqual(library(), [.playlist(playlist, items: [scene, ownVideo]), .wallpaper(workshopVideo),
                                   .wallpaper(ownVideo), .wallpaper(scene)])
    }

    func testWorkshopAndOwnVideosAreOneKind() {
        XCTAssertEqual(LibraryKind(workshopVideo), .video)
        XCTAssertEqual(LibraryKind(ownVideo), .video)
        XCTAssertEqual(LibraryKind(scene), .scene)
        XCTAssertEqual(library(hiding: [.video]).map(\.id), [playlist.id, scene.id])
    }

    func testEachKindHidesOnItsOwn() {
        XCTAssertEqual(library(hiding: [.playlist]).map(\.id), [workshopVideo.id, ownVideo.id, scene.id])
        XCTAssertEqual(library(hiding: [.scene]).map(\.id), [playlist.id, workshopVideo.id, ownVideo.id])
        XCTAssertEqual(library(hiding: [.playlist, .video]).map(\.id), [scene.id])
        XCTAssertTrue(library(hiding: Set(LibraryKind.allCases)).isEmpty)
    }

    func testSearchAppliesWithinTheShownKinds() {
        XCTAssertEqual(library(search: "nami").map(\.id), [workshopVideo.id], "a wallpaper's author matches")
        XCTAssertEqual(library(search: "even").map(\.id), [playlist.id], "a playlist's name matches")
        XCTAssertEqual(library(search: "forest", hiding: [.scene]).map(\.id), [ownVideo.id])
        XCTAssertTrue(library(search: "forest", hiding: [.video]).isEmpty)
    }

    func testEntryKinds() {
        XCTAssertEqual(LibraryEntry.playlist(playlist, items: []).kind, .playlist)
        XCTAssertEqual(LibraryEntry.wallpaper(scene).kind, .scene)
        XCTAssertEqual(LibraryEntry.wallpaper(workshopVideo).kind, .video)
    }
}
