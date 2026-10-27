import XCTest
import Core
@testable import WallpaperMage

// How Home sorts its library (LibraryOrder) and the dates the library keeps for it.
@MainActor
final class LibraryOrderTests: XCTestCase {
    private func day(_ number: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(number) * 86_400) }

    private func order(_ sort: LibrarySort, ascending: Bool = false) -> LibraryOrder {
        LibraryOrder(sort: sort, ascending: ascending)
    }

    // MARK: Sorting

    func testLastAddedOrUpdatedListsTheNewestFirstAndTurnsAroundExactly() {
        let old = VideoItem(path: "/old.mp4")                                   // added before dates were kept
        let older = VideoItem(path: "/older.mp4")
        let video = VideoItem(path: "/v.mp4", updated: day(3))
        let scene = VideoItem(path: "/s.pkg", scene: SceneInfo(), updated: day(5))
        let playlist = Playlist(name: "P", created: day(1), updated: day(4))
        let entries = LibraryEntry.library(videos: [old, older, video, scene], playlists: [playlist], search: "",
                                           hiding: [])

        let newestFirst = order(.updated).sorted(entries).map(\.id)
        XCTAssertEqual(newestFirst, [scene.id, playlist.id, video.id, older.id, old.id])
        XCTAssertEqual(order(.updated, ascending: true).sorted(entries).map(\.id), newestFirst.reversed())
    }

    func testByTypeListsPlaylistsThenScenesThenVideosEachNewestFirst() {
        let videoA = VideoItem(path: "/a.mp4", updated: day(1))
        let videoB = VideoItem(path: "/b.mp4", updated: day(2))
        let sceneA = VideoItem(path: "/a.pkg", scene: SceneInfo(), updated: day(3))
        let sceneB = VideoItem(path: "/b.pkg", scene: SceneInfo())
        let playlistA = Playlist(name: "A", updated: day(1))
        let playlistB = Playlist(name: "B", updated: day(6))
        let entries = LibraryEntry.library(videos: [videoA, sceneA, videoB, sceneB],
                                           playlists: [playlistA, playlistB], search: "", hiding: [])

        XCTAssertEqual(order(.kind).sorted(entries).map(\.id),
                       [playlistB.id, playlistA.id, sceneA.id, sceneB.id, videoB.id, videoA.id])
        XCTAssertEqual(order(.kind, ascending: true).sorted(entries).map(\.id),
                       [videoB.id, videoA.id, sceneA.id, sceneB.id, playlistB.id, playlistA.id],
                       "only the types turn around")
    }

    func testCreationDateListsUnknownDatesLastEitherWay() {
        let early = VideoItem(path: "/early.mp4", created: day(1))
        let late = VideoItem(path: "/late.pkg", scene: SceneInfo(), created: day(9))
        let unknownOld = VideoItem(path: "/u1.mp4", updated: day(2))
        let unknownNew = VideoItem(path: "/u2.mp4", updated: day(7))
        let playlist = Playlist(name: "P", created: day(5), updated: day(5))
        let tie = VideoItem(path: "/tie.mp4", created: day(5), updated: day(8))
        let entries = LibraryEntry.library(videos: [early, late, unknownOld, unknownNew, tie], playlists: [playlist],
                                           search: "", hiding: [])

        XCTAssertEqual(order(.created).sorted(entries).map(\.id),
                       [late.id, tie.id, playlist.id, early.id, unknownNew.id, unknownOld.id])
        XCTAssertEqual(order(.created, ascending: true).sorted(entries).map(\.id),
                       [early.id, tie.id, playlist.id, late.id, unknownNew.id, unknownOld.id])
    }

    func testSortingKeepsTheFilters() {
        let video = VideoItem(path: "/v.mp4", title: "Ocean", updated: day(1))
        let scene = VideoItem(path: "/s.pkg", title: "Ocean City", scene: SceneInfo(), updated: day(2))
        let other = VideoItem(path: "/o.mp4", title: "Forest", updated: day(3))
        let entries = LibraryEntry.library(videos: [video, scene, other], playlists: [Playlist(name: "Ocean")],
                                           search: "ocean", hiding: [.playlist])
        XCTAssertEqual(order(.updated).sorted(entries).map(\.id), [scene.id, video.id])
    }

    func testTheLibraryStartsNewestFirst() {
        XCTAssertEqual(LibraryOrder(), LibraryOrder(sort: .updated, ascending: false))
    }

    // MARK: Dates the library keeps

    func testWhatComesIntoTheLibraryIsDated() throws {
        let model = SettingsModel()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date()

        model.addVideos(urls: [file])
        let video = try XCTUnwrap(model.videos.first)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(video.updated), start)
        XCTAssertEqual(video.created, file.creationDate)

        let downloaded = VideoItem(path: "/L/1/video.mp4", workshopID: "1", created: day(2))
        model.addImported(downloaded)
        let imported = try XCTUnwrap(model.videos.first { $0.id == downloaded.id })
        XCTAssertEqual(imported.created, day(2))
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(imported.updated), start)
    }

    func testAPlaylistIsDatedWhenMadeAndEdited() throws {
        let model = SettingsModel()
        model.createAndEditPlaylist()
        model.finishEditing()
        let made = try XCTUnwrap(model.playlists.first)
        let created = try XCTUnwrap(made.created)
        XCTAssertEqual(made.updated, created)

        model.updatePlaylist(made.id) { $0.name = "Renamed" }
        let edited = try XCTUnwrap(model.playlist(made.id))
        XCTAssertEqual(edited.created, created)
        XCTAssertGreaterThan(try XCTUnwrap(edited.updated), created)

        model.updatePlaylist(made.id) { $0.name = "Renamed" }
        XCTAssertEqual(model.playlist(made.id)?.updated, edited.updated, "no change, no new date")
    }

    func testAnEditTakenBackIsNoChange() throws {
        let model = SettingsModel()
        model.createAndEditPlaylist()
        model.finishEditing()
        let original = try XCTUnwrap(model.playlists.first)
        model.editPlaylist(original.id)
        model.updatePlaylist(original.id) { $0.intervalValue = 42 }
        XCTAssertTrue(model.editHasChanges)
        model.updatePlaylist(original.id) { $0.intervalValue = 5 }
        XCTAssertFalse(model.editHasChanges)
        model.finishEditing()
        XCTAssertEqual(model.playlist(original.id), original, "Done keeps its date too")
    }

    func testLibraryDatesSurviveTheStateFile() throws {
        let item = VideoItem(path: "/v.mp4", created: day(1), updated: day(2))
        let playlist = Playlist(name: "P", created: day(3), updated: day(4))
        let state = LibraryState(videos: [item], playlists: [playlist])
        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.videos, [item])
        XCTAssertEqual(decoded.playlists, [playlist])

        let legacy = try JSONDecoder().decode(Playlist.self, from: Data(#"{"id":"\#(UUID())","name":"Old"}"#.utf8))
        XCTAssertNil(legacy.created)
        XCTAssertNil(legacy.updated)
    }

    // MARK: Workshop

    func testAWorkshopItemKnowsWhenItWasPublished() throws {
        let json = #"""
        {"response":{"publishedfiledetails":[{"publishedfileid":"2961836571","result":1,"consumer_app_id":431960,
        "title":"T","file_size":"1","time_created":"1700000000","time_updated":1700000500,"visibility":0,
        "banned":false,"tags":[{"tag":"Video"}]}]}}
        """#
        let response = try JSONDecoder().decode(WorkshopKit.Wire.Envelope.self, from: Data(json.utf8)).response
        let item = try XCTUnwrap(response.files.first).workshopItem()
        XCTAssertEqual(item.created, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testCreationDatesAreAskedForManyItemsAtOnce() throws {
        let request = WorkshopKit.API.detailsRequest(ids: ["11", "22"])
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        let pairs = Set(body.split(separator: "&").map(String.init))
        XCTAssertTrue(pairs.isSuperset(of: ["itemcount=2", "publishedfileids%5B0%5D=11", "publishedfileids%5B1%5D=22"]),
                      body)
    }
}
