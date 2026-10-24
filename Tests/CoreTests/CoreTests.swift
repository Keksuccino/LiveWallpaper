import XCTest
@testable import Core

// Pure checks only: nothing here may touch ~/Library/Application Support (these run on developers' Macs too).
// Owner: scaffold. Workers may ADD tests in new files.
final class CoreTests: XCTestCase {
    private func decode(_ json: String) throws -> LibraryState {
        try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8))
    }

    func testSchema1StateMigratesToTheDesktopConfig() throws {
        let a = UUID(), b = UUID()
        let state = try decode("""
        {"schema":1,"revision":7,
         "videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"},{"id":"\(b.uuidString)","path":"/v/b.mov"}],
         "selectedID":"\(b.uuidString)","rotateEnabled":false,"intervalValue":7,"intervalUnit":"hours",
         "applyToDesktop":true,"applyToLockScreen":false}
        """)
        XCTAssertEqual(state.schema, 2)
        XCTAssertEqual(state.revision, 7)
        XCTAssertTrue(state.muted)
        XCTAssertEqual(state.desktop.selectedID, b)
        XCTAssertFalse(state.desktop.rotateEnabled)
        XCTAssertEqual(state.desktop.intervalValue, 7)
        XCTAssertEqual(state.desktop.intervalUnit, .hours)
        XCTAssertTrue(state.desktop.enabled)
        XCTAssertEqual(state.videos.map(\.id), [a, b])
        XCTAssertTrue(state.canPlay)
    }

    func testPhase1RecordWithoutSchemaKeyDecodes() throws {
        let state = try decode(#"{"videos":[],"rotateEnabled":true,"intervalValue":0,"intervalUnit":"seconds"}"#)
        XCTAssertEqual(state.schema, 2)
        XCTAssertEqual(state.desktop.intervalValue, 1, "interval clamps to 1...999")
    }

    func testSchema2RoundTripKeepsEverything() throws {
        let item = VideoItem(path: "/L/1/scene.pkg", title: "T", workshopID: "1",
                             scene: SceneInfo(support: .partial, notes: ["Particles are not supported yet."]))
        var state = LibraryState(videos: [item], muted: false,
                                 desktop: PlaybackConfig(enabled: true, selectedID: item.id, rotateEnabled: true))
        state.revision = 3
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(LibraryState.self, from: data)
        XCTAssertEqual(back, state)
        XCTAssertEqual(back.videos[0].kind, .scene)
        XCTAssertFalse(back.muted)
        XCTAssertTrue(back.desktop.rotateEnabled)
    }

    func testStateWithAnOlderLockScreenSectionKeepsTheDesktopAndDropsTheRest() throws {
        let a = UUID(), b = UUID()
        let state = try decode("""
        {"schema":2,"revision":4,"muted":false,"sameForBoth":false,
         "videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"},{"id":"\(b.uuidString)","path":"/v/b.mov"}],
         "desktop":{"enabled":true,"selectedID":"\(a.uuidString)","rotateEnabled":false,"intervalValue":5,"intervalUnit":"minutes"},
         "lock":{"enabled":true,"selectedID":"\(b.uuidString)","rotateEnabled":true,"intervalValue":9,"intervalUnit":"hours"}}
        """)
        XCTAssertEqual(state.desktop.selectedID, a)
        XCTAssertFalse(state.desktop.rotateEnabled)
        XCTAssertFalse(state.muted)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        XCTAssertNil(written?["lock"])
        XCTAssertNil(written?["sameForBoth"])
    }

    func testAssignSelectsAndEnablesTheDesktop() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var state = LibraryState(videos: [a, b], desktop: PlaybackConfig(enabled: false, selectedID: a.id))
        state.assign(b.id)
        XCTAssertEqual(state.desktop.selectedID, b.id)
        XCTAssertTrue(state.desktop.enabled)
        XCTAssertEqual(state.selectedItem?.id, b.id)
        state.assign(UUID())
        XCTAssertEqual(state.desktop.selectedID, b.id, "an id that is not in the library is ignored")
    }

    func testSceneFrameRateDefaultsClampsAndRoundTrips() throws {
        XCTAssertEqual(LibraryState().sceneFPS, 30)
        XCTAssertEqual(LibraryState(sceneFPS: 1000).sceneFPS, 120)
        XCTAssertEqual(LibraryState(sceneFPS: 1).sceneFPS, 10)
        let back = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(LibraryState(sceneFPS: 45)))
        XCTAssertEqual(back.sceneFPS, 45)
        let old = try decode(#"{"schema":2,"revision":1,"videos":[]}"#)
        XCTAssertEqual(old.sceneFPS, 30, "a state.json from before the setting exists defaults to 30")
    }

    func testStillDelayDefaultsClampsAndRoundTrips() throws {
        XCTAssertEqual(LibraryState().stillDelay, LibraryState.defaultStillDelay)
        XCTAssertTrue(LibraryState.stillDelayOptions.contains(LibraryState.defaultStillDelay))
        XCTAssertEqual(try decode(#"{"schema":2,"revision":1,"videos":[]}"#).stillDelay, LibraryState.defaultStillDelay,
                       "a state.json from before the setting exists gets the default")
        XCTAssertEqual(try decode(#"{"schema":2,"videos":[],"stillDelay":60}"#).stillDelay, 5)
        XCTAssertEqual(try decode(#"{"schema":2,"videos":[],"stillDelay":-1}"#).stillDelay, 0)
        var state = LibraryState()
        state.stillDelay = 0.5
        XCTAssertEqual(try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).stillDelay, 0.5)
    }

    func testPlaylistFiltersMissingIDs() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        let state = LibraryState(videos: [a, b], desktop: PlaybackConfig(playlist: [b.id, UUID()]))
        XCTAssertEqual(state.items.map(\.id), [b.id])
        XCTAssertFalse(state.hasMultipleItems)
    }

    func testRotationNeedsACuratedPlaylistOfTwo() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var state = LibraryState(videos: [a, b], desktop: PlaybackConfig(rotateEnabled: true))
        XCTAssertFalse(state.rotates, "without a playlist the selected wallpaper stays")
        state.desktop.playlist = [a.id, b.id]
        XCTAssertTrue(state.rotates)
        state.desktop.playlist = [a.id]
        XCTAssertFalse(state.rotates)
    }

    func testContentStampFollowsTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lw-\(UUID().uuidString).pkg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("one".utf8).write(to: file)
        let item = VideoItem(path: file.path)
        let first = item.contentStamp
        XCTAssertEqual(item.contentStamp, first)
        try Data("longer content".utf8).write(to: file)
        XCTAssertNotEqual(item.contentStamp, first)
    }
}
