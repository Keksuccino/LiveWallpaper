import XCTest
@testable import Core

// Pure checks only: nothing here may touch ~/Library/Application Support (these run on developers' Macs too).
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
        XCTAssertFalse(state.muted)
        XCTAssertEqual(state.videos.map(\.id), [a, b])
        XCTAssertNil(state.playlist)
        assertEveryDisplay(state) { config in
            XCTAssertEqual(config.wallpaperID, b)
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
            XCTAssertTrue(config.rotateEnabled)
            XCTAssertEqual(config.power.batteryMode, .pause)
            XCTAssertEqual(config.options(for: a).fps, 24)
            XCTAssertEqual(config.options(for: b).fps, 45, "a wallpaper without its own rate keeps the desktop's")
            XCTAssertEqual(config.options(for: a).alignment, .cover)
        }
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        for key in ["lock", "sameForBoth", "desktop", "sceneOptions", "power", "sceneFPS"] {
            XCTAssertNil(written?[key], key)
        }
        XCTAssertEqual(written?["muted"] as? Bool, false, "from schema 4 on `muted` is the app's mute")
    }

    func testADisabledDesktopMigratesWithoutAWallpaper() throws {
        let a = UUID()
        let state = try decode("""
        {"schema":2,"videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"}],
         "desktop":{"enabled":false,"selectedID":"\(a.uuidString)","rotateEnabled":false,"intervalValue":5,"intervalUnit":"minutes"}}
        """)
        assertEveryDisplay(state) { XCTAssertNil($0.wallpaperID) }
    }

    func testSchema4DisplayFrameRatesMoveToEveryWallpaper() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let state = try decode("""
        {"schema":4,"revision":1,
         "videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"},{"id":"\(b.uuidString)","path":"/v/b.mp4"},
                   {"id":"\(c.uuidString)","path":"/v/c.mp4"}],
         "displays":{
           "D1":{"wallpaperID":"\(a.uuidString)","sceneFPS":60,"power":{"frameRateCap":45,"batteryMode":"pause",
                 "batteryRenderScale":0.5,"batteryFPS":24,"skipRepeatedFrames":true,"renderOnlyOnChange":false},
                 "sceneOptions":{"\(a.uuidString)":{"fps":24},"\(b.uuidString)":{"volume":0.5}}},
           "D2":{"wallpaperID":"\(a.uuidString)","sceneFPS":30,"sceneOptions":{"\(a.uuidString)":{"fps":60}}}}}
        """)
        let d1 = state.config(for: "D1"), d2 = state.config(for: "D2")
        XCTAssertEqual(d1.options(for: a).fps, 24, "a wallpaper's own rate stays when it is below the cap")
        XCTAssertEqual(d1.options(for: b).fps, 45, "the display's rate, capped")
        XCTAssertEqual(d1.options(for: b).volume, 0.5)
        XCTAssertEqual(d1.options(for: c).fps, 45, "a wallpaper without settings gets the display's rate too")
        XCTAssertEqual(d1.power.batteryMode, .pause)
        XCTAssertEqual(d2.options(for: a).fps, 60)
        XCTAssertNil(d2.wallpaperOptions[c.uuidString], "the default rate needs no entry")
        let back = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state, "a schema 5 file is not migrated again")
    }

    func testRoundTripKeepsEverything() throws {
        let item = VideoItem(path: "/L/1/scene.pkg", title: "T", workshopID: "1",
                             scene: SceneInfo(support: .partial, notes: ["Particles are not supported yet."]))
        var config = DisplayConfig(wallpaperID: item.id, rotateEnabled: true)
        config.wallpaperOptions[item.id.uuidString] = WallpaperOptions(
            volume: 0.3, muted: true, rate: 1.5, alignment: .free, position: 0.2, alignX: 0.1, alignY: 0.9, zoom: 1.5, flip: true,
            blurBars: false, colorAdjust: true, brightness: 0.7, contrast: 0.4, saturation: 0.6, hue: 0.1,
            filter: "lutx32_amber", filterStrength: 0.5, mouseParallax: false, fps: 45, renderScale: 0.5,
            audioResponse: true, antialiasing: true, properties: ["clock": .bool(true), "tint": .color(red: 1, green: 0, blue: 0)])
        var state = LibraryState(videos: [item], playlist: [item.id], displays: ["D1": config, "D2": DisplayConfig()],
                                 masterVolume: 0.4, muted: true)
        state.revision = 3
        let back = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
        XCTAssertEqual(back.videos[0].kind, .scene)
        XCTAssertTrue(back.muted, "a schema 4 file keeps the app muted")
        XCTAssertTrue(back.config(for: "D1").options(for: item.id).muted)
        XCTAssertEqual(back.masterVolume, 0.4)
    }

    func testOlderFilesLeaveTheSoundOnAndKeepTheirLook() throws {
        let a = UUID(), b = UUID(), c = UUID()
        let state = try decode("""
        {"schema":3,"muted":true,"videos":[],"displays":{"D1":{"muted":true,"sceneOptions":{
           "\(a.uuidString)":{"fitMode":"matchBlurred","zoom":1.7,"panX":0.1,"volume":0.5},
           "\(b.uuidString)":{"fitMode":"fit"},
           "\(c.uuidString)":{"fitMode":"none","renderScale":0.5}}}}}
        """)
        let config = state.config(for: "D1")
        XCTAssertFalse(state.muted, "older files muted by default; their mute is not the app's")
        XCTAssertFalse(config.options(for: a).muted)
        XCTAssertEqual(state.masterVolume, 1)
        let blurred = config.options(for: a)
        XCTAssertEqual(blurred.alignment, .fill)
        XCTAssertTrue(blurred.blurBars)
        XCTAssertEqual(blurred.zoom, 1, "the old zoom meant something else")
        XCTAssertEqual(blurred.alignX, 0.5)
        XCTAssertEqual(blurred.volume, 0.5)
        XCTAssertEqual(config.options(for: b).alignment, .fill)
        XCTAssertFalse(config.options(for: b).blurBars)
        XCTAssertEqual(config.options(for: c).alignment, .center)
        XCTAssertEqual(config.options(for: c).renderScale, 0.5)
    }

    func testPresetsRoundTripFollowWorkshopItemsAndLeaveWithThem() throws {
        let a = VideoItem(path: "/L/1/scene.pkg", workshopID: "1"), b = VideoItem(path: "/b.mp4")
        var state = LibraryState(videos: [a, b])
        state.presets[a.presetKey] = [WallpaperPreset(name: "Night", options: WallpaperOptions(brightness: 0.3))]
        state.presets[b.presetKey] = [WallpaperPreset(name: "Big", options: WallpaperOptions(alignment: .fill))]
        let back = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back.presets, state.presets)
        XCTAssertEqual(a.presetKey, "1", "a Workshop item keeps its presets under its Workshop id")
        state.remove([a.id])
        XCTAssertNil(state.presets["1"])
        XCTAssertEqual(state.presets[b.presetKey]?.first?.name, "Big")
    }

    func testBuiltInOptionsApplyWithoutTheScenesOwn() {
        let mine = WallpaperOptions(fps: 24, renderScale: 0.5, properties: ["clock": .bool(true)])
        let other = WallpaperOptions(volume: 0.2, alignment: .free, flip: true, colorAdjust: true, fps: 60,
                                     properties: ["rain": .bool(false)])
        let merged = mine.withBuiltIns(of: other)
        XCTAssertEqual(merged.volume, 0.2)
        XCTAssertEqual(merged.alignment, .free)
        XCTAssertTrue(merged.flip && merged.colorAdjust)
        XCTAssertEqual(merged.fps, 24)
        XCTAssertEqual(merged.renderScale, 0.5)
        XCTAssertEqual(merged.properties, ["clock": .bool(true)])
    }

    func testWallpaperOptionsClampAndKnowWhenTheyGradeColour() {
        let options = WallpaperOptions(volume: 3, rate: 9, position: -1, zoom: 5, brightness: 2, filter: "")
        XCTAssertEqual(options.volume, 1)
        XCTAssertEqual(options.rate, 2)
        XCTAssertEqual(options.position, 0)
        XCTAssertEqual(options.zoom, 2)
        XCTAssertEqual(WallpaperOptions(fps: 1000).fps, 120, "the frame rate clamps to 10...120")
        XCTAssertEqual(WallpaperOptions(fps: 1).fps, 10)
        XCTAssertNil(options.filter, "an empty filter name is no filter")
        XCTAssertFalse(options.adjustsColor, "the colour values apply only with the colour options on")
        XCTAssertTrue(WallpaperOptions(colorAdjust: true, hue: 0.6).gradesColor)
        XCTAssertFalse(WallpaperOptions(colorAdjust: true).gradesColor, "all values in the middle change nothing")
        XCTAssertTrue(WallpaperOptions(filter: "tower").gradesColor)
        XCTAssertFalse(WallpaperOptions(filter: "tower", filterStrength: 0).gradesColor)
    }

    func testDisplayConfigFillsMissingKeysWithDefaults() throws {
        let config = try JSONDecoder().decode(DisplayConfig.self, from: Data("{}".utf8))
        XCTAssertNil(config.wallpaperID)
        XCTAssertFalse(config.rotateEnabled)
        let options = try JSONDecoder().decode(WallpaperOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options, .standard)
        XCTAssertEqual(options.fps, WallpaperOptions.defaultFPS)
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

    func testRemovingItemsClearsDisplaysPlaylistAndWallpaperOptions() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var config = DisplayConfig(wallpaperID: a.id)
        config.wallpaperOptions = [a.id.uuidString: WallpaperOptions(zoom: 2), b.id.uuidString: WallpaperOptions(zoom: 0.5)]
        var state = LibraryState(videos: [a, b], playlist: [a.id, b.id],
                                 displays: ["D1": config, "D2": DisplayConfig(wallpaperID: b.id)])
        state.remove([a.id])
        XCTAssertEqual(state.videos.map(\.id), [b.id])
        XCTAssertEqual(state.playlist, [b.id])
        XCTAssertNil(state.config(for: "D1").wallpaperID)
        XCTAssertNil(state.config(for: "D1").wallpaperOptions[a.id.uuidString])
        XCTAssertEqual(state.config(for: "D1").options(for: b.id).zoom, 0.5)
        XCTAssertEqual(state.config(for: "D2").wallpaperID, b.id)
    }

    func testReplacingAnItemMovesItsPlacesAndSettings() {
        let old = VideoItem(path: "/L/1/scene.pkg", workshopID: "1"), other = VideoItem(path: "/b.mp4")
        let fresh = VideoItem(path: "/L/1/scene.pkg", workshopID: "1")
        var config = DisplayConfig(wallpaperID: old.id)
        config.wallpaperOptions[old.id.uuidString] = WallpaperOptions(zoom: 2)
        var state = LibraryState(videos: [old, other], playlist: [other.id, old.id], displays: ["D1": config])
        state.replace(old.id, with: fresh)
        XCTAssertEqual(state.videos.map(\.id), [fresh.id, other.id])
        XCTAssertEqual(state.playlist, [other.id, fresh.id])
        XCTAssertEqual(state.config(for: "D1").wallpaperID, fresh.id)
        XCTAssertEqual(state.config(for: "D1").options(for: fresh.id).zoom, 2)
        XCTAssertNil(state.config(for: "D1").wallpaperOptions[old.id.uuidString])
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
