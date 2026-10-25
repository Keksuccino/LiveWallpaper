import XCTest
import Core
@testable import WallpaperMage

// The playlist editor's session in SettingsModel: Done keeps an edit, every other way out undoes it, asking first
// when there is something to undo. The model is never bootstrapped, so nothing reaches the service or ~/Library.
@MainActor
final class PlaylistEditTests: XCTestCase {
    private var model: SettingsModel!
    private var a: VideoItem!
    private var b: VideoItem!

    override func setUp() async throws {
        model = SettingsModel()
        a = VideoItem(path: "/v/a.mp4", workshopID: "1")
        b = VideoItem(path: "/v/b.mp4")
        model.videos = [a, b]
    }

    /// A playlist of `a` and `b` that exists before the editor opens.
    private func existingPlaylist() -> Playlist {
        model.createAndEditPlaylist(with: [a.id, b.id])
        model.finishEditing()
        return model.playlists[0]
    }

    private func change(_ id: Playlist.ID) {
        model.updatePlaylist(id) { playlist in
            playlist.name += " edited"
            playlist.items = [b.id]
            playlist.intervalValue = 42
            playlist.transition = .slide
        }
        model.updateOptions(in: .playlist(id), for: b.id) { $0.zoom = 1.7 }
    }

    func testDiscardingPutsThePlaylistBackAsItWas() {
        let original = existingPlaylist()
        model.editPlaylist(original.id)
        change(original.id)
        XCTAssertTrue(model.editHasChanges)

        var left = false
        model.leaveEditor(then: { left = true })
        XCTAssertNotNil(model.leaveRequest, "there is something to undo, so it asks")
        XCTAssertFalse(left)
        XCTAssertEqual(model.editingPlaylistID, original.id)

        model.answerLeaveRequest(discard: true)
        XCTAssertTrue(left)
        XCTAssertNil(model.leaveRequest)
        XCTAssertNil(model.editingPlaylistID)
        XCTAssertEqual(model.playlist(original.id), original)
    }

    func testKeepingEditingStaysWithTheChanges() {
        let original = existingPlaylist()
        model.editPlaylist(original.id)
        change(original.id)
        var left = false, stayed = false
        model.leaveEditor(then: { left = true }, otherwise: { stayed = true })
        model.answerLeaveRequest(discard: false)
        XCTAssertTrue(stayed)
        XCTAssertFalse(left)
        XCTAssertEqual(model.editingPlaylistID, original.id)
        XCTAssertEqual(model.playlist(original.id)?.intervalValue, 42)
    }

    func testLeavingWithoutChangesDoesNotAsk() {
        let original = existingPlaylist()
        model.editPlaylist(original.id)
        var left = false
        model.leaveEditor(then: { left = true })
        XCTAssertTrue(left)
        XCTAssertNil(model.leaveRequest)
        XCTAssertNil(model.editingPlaylistID)
        XCTAssertEqual(model.playlist(original.id), original)
    }

    func testDoneKeepsTheChanges() {
        let original = existingPlaylist()
        model.editPlaylist(original.id)
        change(original.id)
        model.finishEditing()
        XCTAssertNil(model.editingPlaylistID)
        XCTAssertEqual(model.playlist(original.id)?.items, [b.id])
        XCTAssertEqual(model.playlist(original.id)?.transition, .slide)
        var left = false
        model.leaveEditor(then: { left = true })
        XCTAssertTrue(left, "with the editor closed nothing is undone")
        XCTAssertEqual(model.playlist(original.id)?.options(for: b.id).zoom, 1.7)
    }

    func testUndoingANewPlaylistDeletesIt() throws {
        model.createAndEditPlaylist(with: [a.id])
        XCTAssertFalse(model.editHasChanges)
        model.leaveEditor(then: {})
        XCTAssertTrue(model.playlists.isEmpty, "an untouched new playlist goes without asking")

        model.createAndEditPlaylist(with: [a.id])
        let id = try XCTUnwrap(model.editingPlaylistID)
        change(id)
        model.leaveEditor(then: {})
        XCTAssertNotNil(model.leaveRequest)
        model.answerLeaveRequest(discard: true)
        XCTAssertTrue(model.playlists.isEmpty)
    }

    func testAWallpaperDownloadedAgainDuringTheEditStaysOnUndo() {
        let original = existingPlaylist()
        model.editPlaylist(original.id)
        change(original.id)
        let fresh = VideoItem(path: "/v/a.mp4", workshopID: "1")
        model.addImported(fresh)
        model.leaveEditor(then: {})
        model.answerLeaveRequest(discard: true)
        XCTAssertEqual(model.playlist(original.id)?.items, [fresh.id, b.id])
        XCTAssertEqual(model.playlist(original.id)?.name, original.name)
    }

    func testDeletingThePlaylistClosesItsEditor() {
        let original = existingPlaylist()
        model.editPlaylist(original.id)
        change(original.id)
        model.deletePlaylist(original.id)
        XCTAssertNil(model.editingPlaylistID)
        XCTAssertTrue(model.playlists.isEmpty)
        var left = false
        model.leaveEditor(then: { left = true })
        XCTAssertTrue(left)
        XCTAssertTrue(model.playlists.isEmpty, "nothing comes back")
    }
}
