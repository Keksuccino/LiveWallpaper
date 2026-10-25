import XCTest
@testable import Core

// Pure checks only: nothing here may touch ~/Library/Application Support (these run on developers' Macs too).
// Owner: scaffold. Workers may ADD tests in new files.
final class CoreTests: XCTestCase {
    private func decode(_ json: String) throws -> LibraryState {
        try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8))
    }

    /// Older files give their one desktop setting to every display connected while the test runs.
    private func assertEveryDisplay(_ state: LibraryState, _ check: (DisplayConfig) -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(state.displays.keys), Set(DisplayIdentity.active()), file: file, line: line)
        state.displays.values.forEach(check)
    }

    func testSchema1StateMigratesToEveryDisplay() throws {
        let a = UUID(), b = UUID()
        let state = try decode("""
        {"schema":1,"revision":7,
         "videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"},{"id":"\(b.uuidString)","path":"/v/b.mov"}],
         "selectedID":"\(b.uuidString)","rotateEnabled":false,"intervalValue":7,"intervalUnit":"hours",
         "applyToDesktop":true,"applyToLockScreen":false}
        """)
        XCTAssertEqual(state.schema, LibraryState.currentSchema)
        XCTAssertEqual(state.revision, 7)
        XCTAssertEqual(state.videos.map(\.id), [a, b])
        XCTAssertNil(state.playlist)
        assertEveryDisplay(state) { config in
            XCTAssertEqual(config.wallpaperID, b)
            XCTAssertTrue(config.muted)
            XCTAssertFalse(config.rotateEnabled)
            XCTAssertEqual(config.intervalValue, 7)
            XCTAssertEqual(config.intervalUnit, .hours)
        }
    }

    func testPhase1RecordWithoutSchemaKeyDecodes() throws {
        let state = try decode(#"{"videos":[],"rotateEnabled":true,"intervalValue":0,"intervalUnit":"seconds"}"#)
        XCTAssertEqual(state.schema, LibraryState.currentSchema)
        assertEveryDisplay(state) { XCTAssertEqual($0.intervalValue, 1, "interval clamps to 1...999") }
    }

    func testSchema2StateMovesItsSettingsToEveryDisplayAndDropsTheLockScreen() throws {
        let a = UUID(), b = UUID()
        let state = try decode("""
        {"schema":2,"revision":4,"muted":false,"sameForBoth":false,"sceneFPS":45,
         "videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"},{"id":"\(b.uuidString)","path":"/v/b.mov"}],
         "sceneOptions":{"\(a.uuidString)":{"fps":24,"renderScale":0.5,"zoom":1,"fitMode":"fill","panX":0.5,"panY":0.5,
                         "volume":1,"audioResponse":false,"antialiasing":false,"properties":{}}},
         "power":{"batteryMode":"pause","batteryRenderScale":0.5,"batteryFPS":24,"skipRepeatedFrames":true,
                  "renderOnlyOnChange":false},
         "desktop":{"enabled":true,"selectedID":"\(a.uuidString)","playlist":["\(b.uuidString)","\(a.uuidString)"],
                    "rotateEnabled":true,"intervalValue":5,"intervalUnit":"minutes"},
         "lock":{"enabled":true,"selectedID":"\(b.uuidString)","rotateEnabled":true,"intervalValue":9,"intervalUnit":"hours"}}
        """)
        XCTAssertEqual(state.playlist, [b, a])
        assertEveryDisplay(state) { config in
            XCTAssertEqual(config.wallpaperID, a)
            XCTAssertFalse(config.muted)
            XCTAssertTrue(config.rotateEnabled)
            XCTAssertEqual(config.sceneFPS, 45)
            XCTAssertEqual(config.power.batteryMode, .pause)
            XCTAssertEqual(config.sceneOptions(for: a).fps, 24)
            XCTAssertEqual(config.sceneOptions(for: a).fitMode, .fill)
        }
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        for key in ["lock", "sameForBoth", "desktop", "muted", "sceneOptions", "power", "sceneFPS"] {
            XCTAssertNil(written?[key], key)
        }
    }

    func testADisabledDesktopMigratesWithoutAWallpaper() throws {
        let a = UUID()
        let state = try decode("""
        {"schema":2,"videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"}],
         "desktop":{"enabled":false,"selectedID":"\(a.uuidString)","rotateEnabled":false,"intervalValue":5,"intervalUnit":"minutes"}}
        """)
        assertEveryDisplay(state) { XCTAssertNil($0.wallpaperID) }
    }

    func testSchema3RoundTripKeepsEverything() throws {
        let item = VideoItem(path: "/L/1/scene.pkg", title: "T", workshopID: "1",
                             scene: SceneInfo(support: .partial, notes: ["Particles are not supported yet."]))
        var config = DisplayConfig(wallpaperID: item.id, muted: false, rotateEnabled: true, sceneFPS: 60)
        config.sceneOptions[item.id.uuidString] = SceneOptions(zoom: 1.5, fitMode: .fit)
        var state = LibraryState(videos: [item], playlist: [item.id], displays: ["D1": config, "D2": DisplayConfig()])
        state.revision = 3
        let back = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
        XCTAssertEqual(back.videos[0].kind, .scene)
        XCTAssertEqual(back.config(for: "D1").sceneOptions(for: item.id).zoom, 1.5)
    }

    func testDisplayConfigFillsMissingKeysWithDefaults() throws {
        let config = try JSONDecoder().decode(DisplayConfig.self, from: Data(#"{"sceneFPS":1000}"#.utf8))
        XCTAssertNil(config.wallpaperID)
        XCTAssertTrue(config.muted)
        XCTAssertFalse(config.rotateEnabled)
        XCTAssertEqual(config.sceneFPS, 120, "the frame rate clamps to 10...120")
        XCTAssertEqual(DisplayConfig().sceneFPS, LibraryState.defaultSceneFPS)
        XCTAssertEqual(LibraryState().config(for: "unknown"), DisplayConfig())
    }

    func testSetWallpaperTakesLibraryItemsOnly() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var state = LibraryState(videos: [a, b])
        state.setWallpaper(b.id, on: "D1")
        XCTAssertEqual(state.config(for: "D1").wallpaperID, b.id)
        XCTAssertNil(state.config(for: "D2").wallpaperID, "other displays keep theirs")
        state.setWallpaper(UUID(), on: "D1")
        XCTAssertEqual(state.config(for: "D1").wallpaperID, b.id, "an id that is not in the library is ignored")
        state.setWallpaper(nil, on: "D1")
        XCTAssertNil(state.config(for: "D1").wallpaperID)
    }

    func testRemovingItemsClearsDisplaysPlaylistAndSceneSettings() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var config = DisplayConfig(wallpaperID: a.id)
        config.sceneOptions = [a.id.uuidString: SceneOptions(zoom: 2), b.id.uuidString: SceneOptions(zoom: 0.5)]
        var state = LibraryState(videos: [a, b], playlist: [a.id, b.id],
                                 displays: ["D1": config, "D2": DisplayConfig(wallpaperID: b.id)])
        state.remove([a.id])
        XCTAssertEqual(state.videos.map(\.id), [b.id])
        XCTAssertEqual(state.playlist, [b.id])
        XCTAssertNil(state.config(for: "D1").wallpaperID)
        XCTAssertNil(state.config(for: "D1").sceneOptions[a.id.uuidString])
        XCTAssertEqual(state.config(for: "D1").sceneOptions(for: b.id).zoom, 0.5)
        XCTAssertEqual(state.config(for: "D2").wallpaperID, b.id)
    }

    func testReplacingAnItemMovesItsPlacesAndSettings() {
        let old = VideoItem(path: "/L/1/scene.pkg", workshopID: "1"), other = VideoItem(path: "/b.mp4")
        let fresh = VideoItem(path: "/L/1/scene.pkg", workshopID: "1")
        var config = DisplayConfig(wallpaperID: old.id)
        config.sceneOptions[old.id.uuidString] = SceneOptions(zoom: 2)
        var state = LibraryState(videos: [old, other], playlist: [other.id, old.id], displays: ["D1": config])
        state.replace(old.id, with: fresh)
        XCTAssertEqual(state.videos.map(\.id), [fresh.id, other.id])
        XCTAssertEqual(state.playlist, [other.id, fresh.id])
        XCTAssertEqual(state.config(for: "D1").wallpaperID, fresh.id)
        XCTAssertEqual(state.config(for: "D1").sceneOptions(for: fresh.id).zoom, 2)
        XCTAssertNil(state.config(for: "D1").sceneOptions[old.id.uuidString])
    }

    func testStillDelayDefaultsClampsAndRoundTrips() throws {
        XCTAssertEqual(LibraryState().stillDelay, LibraryState.defaultStillDelay)
        XCTAssertTrue(LibraryState.stillDelayOptions.contains(LibraryState.defaultStillDelay))
        XCTAssertEqual(try decode(#"{"schema":2,"revision":1,"videos":[]}"#).stillDelay, LibraryState.defaultStillDelay,
                       "a state.json from before the setting exists gets the default")
        XCTAssertEqual(try decode(#"{"schema":3,"videos":[],"displays":{},"stillDelay":60}"#).stillDelay, 5)
        XCTAssertEqual(try decode(#"{"schema":3,"videos":[],"displays":{},"stillDelay":-1}"#).stillDelay, 0)
        var state = LibraryState()
        state.stillDelay = 0.5
        XCTAssertEqual(try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state)).stillDelay, 0.5)
    }

    func testPlaylistSkipsMissingIDs() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        let state = LibraryState(videos: [a, b], playlist: [b.id, UUID()])
        XCTAssertEqual(state.playlistItems.map(\.id), [b.id])
        XCTAssertFalse(state.canRotate)
        XCTAssertEqual(LibraryState(videos: [a, b]).playlistItems, [], "no playlist, nothing to rotate")
    }

    func testRotationNeedsAPlaylistOfTwoAndIsPerDisplay() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var state = LibraryState(videos: [a, b], displays: ["D1": DisplayConfig(rotateEnabled: true)])
        XCTAssertFalse(state.rotates("D1"), "without a playlist the wallpaper stays")
        state.playlist = [a.id, b.id]
        XCTAssertTrue(state.rotates("D1"))
        XCTAssertFalse(state.rotates("D2"), "rotation is turned on per display")
        state.playlist = [a.id]
        XCTAssertFalse(state.rotates("D1"))
    }

    func testAgentRecordFromAnOlderVersionDecodes() throws {
        let record = try JSONDecoder().decode(
            AgentRecord.self, from: Data(#"{"wantsRunning":true,"aerialSlots":["a.mov"],"legacyImported":true}"#.utf8))
        XCTAssertEqual(record, AgentRecord(aerialSlots: ["a.mov"]))
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
