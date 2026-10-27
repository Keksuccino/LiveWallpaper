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
        XCTAssertEqual(state.playlists, [])
        assertEveryDisplay(state) { XCTAssertEqual($0.content, .wallpaper(b)) }
    }

    func testPhase1RecordWithoutSchemaKeyDecodes() throws {
        let state = try decode(#"{"videos":[],"rotateEnabled":true,"intervalValue":0,"intervalUnit":"seconds"}"#)
        XCTAssertEqual(state.schema, LibraryState.currentSchema)
        assertEveryDisplay(state) { XCTAssertNil($0.content) }
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
        XCTAssertEqual(state.playlists, [], "the single playlist of older files is not kept")
        assertEveryDisplay(state) { config in
            XCTAssertEqual(config.content, .wallpaper(a))
            XCTAssertEqual(config.power.batteryMode, .pause)
            XCTAssertEqual(config.options(for: a).fps, 24)
            XCTAssertEqual(config.options(for: b).fps, 45, "a wallpaper without its own rate keeps the desktop's")
            XCTAssertEqual(config.options(for: a).alignment, .cover)
        }
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        for key in ["lock", "sameForBoth", "desktop", "sceneOptions", "power", "sceneFPS", "playlist"] {
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
        assertEveryDisplay(state) { XCTAssertNil($0.content) }
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
        XCTAssertEqual(d1.content, .wallpaper(a))
        let back = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state, "a current file is not migrated again")
    }

    func testSchema5DisplaysKeepTheirWallpaperAndDropRotation() throws {
        let a = UUID(), b = UUID()
        let state = try decode("""
        {"schema":5,"videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"},{"id":"\(b.uuidString)","path":"/v/b.mp4"}],
         "playlist":["\(a.uuidString)","\(b.uuidString)"],
         "displays":{"D1":{"wallpaperID":"\(b.uuidString)","rotateEnabled":true,"intervalValue":3,"intervalUnit":"hours",
                           "sceneOptions":{"\(b.uuidString)":{"zoom":1.5}}}}}
        """)
        XCTAssertEqual(state.playlists, [])
        XCTAssertEqual(state.config(for: "D1").content, .wallpaper(b))
        XCTAssertEqual(state.config(for: "D1").options(for: b).zoom, 1.5)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any]
        let display = (written?["displays"] as? [String: Any])?["D1"] as? [String: Any]
        XCTAssertNil(display?["rotateEnabled"])
        XCTAssertNil(written?["playlist"])
    }

    /// A scene record may hold keys this version does not know (`support`, `notes`); decoding ignores them.
    func testSceneRecordWithUnknownKeysDecodes() throws {
        let json = #"{"support": "partial", "notes": ["Particles are not supported yet."], "designWidth": 2560, "designHeight": 1440, "needsSharedAssets": true, "analysisRevision": 1}"#
        let info = try JSONDecoder().decode(SceneInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info, SceneInfo(designWidth: 2560, designHeight: 1440, needsSharedAssets: true))
    }

    func testRoundTripKeepsEverything() throws {
        let item = VideoItem(path: "/L/1/scene.pkg", title: "T", workshopID: "1",
                             scene: SceneInfo(designWidth: 2560, designHeight: 1440, needsSharedAssets: true))
        var config = DisplayConfig(content: .wallpaper(item.id))
        config.wallpaperOptions[item.id.uuidString] = WallpaperOptions(
            volume: 0.3, muted: true, rate: 1.5, alignment: .free, position: 0.2, alignX: 0.1, alignY: 0.9, zoom: 1.5, flip: true,
            blurBars: false, colorAdjust: true, brightness: 0.7, contrast: 0.4, saturation: 0.6, hue: 0.1,
            filter: "lutx32_amber", filterStrength: 0.5, mouseParallax: false, fps: 45, renderScale: 0.5,
            audioResponse: true, antialiasing: true, properties: ["clock": .bool(true), "tint": .color(red: 1, green: 0, blue: 0)])
        let playlist = Playlist(name: "Night", items: [item.id],
                                wallpaperOptions: [item.id.uuidString: WallpaperOptions(volume: 0.1)],
                                intervalValue: 30, intervalUnit: .seconds, transition: .blur, transitionDuration: 2.5,
                                image: "picture.jpg")
        var state = LibraryState(videos: [item], playlists: [playlist],
                                 displays: ["D1": config, "D2": DisplayConfig(content: .playlist(playlist.id))],
                                 masterVolume: 0.4, muted: true)
        state.revision = 3
        let back = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(back, state)
        XCTAssertEqual(back.videos[0].kind, .scene)
        XCTAssertTrue(back.muted, "a schema 4 file keeps the app muted")
        XCTAssertTrue(back.config(for: "D1").options(for: item.id).muted)
        XCTAssertEqual(back.config(for: "D2").content, .playlist(playlist.id))
        XCTAssertEqual(back.playlists, [playlist])
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

    func testSettingsApplyWithoutTheScenesOwnProperties() {
        let mine = WallpaperOptions(fps: 24, renderScale: 0.5, properties: ["clock": .bool(true)])
        let other = WallpaperOptions(volume: 0.2, alignment: .free, flip: true, colorAdjust: true, fps: 60,
                                     audioResponse: true, antialiasing: true, properties: ["rain": .bool(false)])
        let fromScene = mine.withSettings(of: other, performance: true)
        XCTAssertEqual(fromScene.volume, 0.2)
        XCTAssertEqual(fromScene.alignment, .free)
        XCTAssertTrue(fromScene.flip && fromScene.colorAdjust)
        XCTAssertEqual(fromScene.fps, 60)
        XCTAssertEqual(fromScene.renderScale, 1)
        XCTAssertTrue(fromScene.audioResponse && fromScene.antialiasing)
        XCTAssertEqual(fromScene.properties, ["clock": .bool(true)])

        let fromVideo = mine.withSettings(of: other, performance: false)
        XCTAssertEqual(fromVideo.volume, 0.2)
        XCTAssertEqual(fromVideo.alignment, .free)
        XCTAssertEqual(fromVideo.fps, 24)
        XCTAssertEqual(fromVideo.renderScale, 0.5)
        XCTAssertFalse(fromVideo.audioResponse || fromVideo.antialiasing)
        XCTAssertEqual(fromVideo.properties, ["clock": .bool(true)])
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
        XCTAssertNil(config.content)
        let options = try JSONDecoder().decode(WallpaperOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options, .standard)
        XCTAssertEqual(options.fps, WallpaperOptions.defaultFPS)
        XCTAssertEqual(LibraryState().config(for: "unknown"), DisplayConfig())
    }

    func testSetContentTakesLibraryItemsAndPlaylistsOnly() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        let playlist = Playlist(name: "P", items: [a.id])
        var state = LibraryState(videos: [a, b], playlists: [playlist])
        state.setContent(.wallpaper(b.id), on: "D1")
        XCTAssertEqual(state.config(for: "D1").content, .wallpaper(b.id))
        XCTAssertNil(state.config(for: "D2").content, "other displays keep theirs")
        state.setContent(.wallpaper(UUID()), on: "D1")
        XCTAssertEqual(state.config(for: "D1").content, .wallpaper(b.id), "an id that is not in the library is ignored")
        state.setContent(.playlist(UUID()), on: "D1")
        XCTAssertEqual(state.config(for: "D1").content, .wallpaper(b.id), "so is a playlist that does not exist")
        state.setContent(.playlist(playlist.id), on: "D1")
        XCTAssertEqual(state.config(for: "D1").content, .playlist(playlist.id))
        state.setContent(nil, on: "D1")
        XCTAssertNil(state.config(for: "D1").content)
    }

    func testRemovingItemsClearsDisplaysPlaylistsAndWallpaperOptions() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var config = DisplayConfig(content: .wallpaper(a.id))
        config.wallpaperOptions = [a.id.uuidString: WallpaperOptions(zoom: 2), b.id.uuidString: WallpaperOptions(zoom: 0.5)]
        let playlist = Playlist(name: "P", items: [a.id, b.id],
                                wallpaperOptions: [a.id.uuidString: WallpaperOptions(zoom: 1.2),
                                                   b.id.uuidString: WallpaperOptions(zoom: 1.4)])
        var state = LibraryState(videos: [a, b], playlists: [playlist],
                                 displays: ["D1": config, "D2": DisplayConfig(content: .wallpaper(b.id)),
                                            "D3": DisplayConfig(content: .playlist(playlist.id))])
        state.remove([a.id])
        XCTAssertEqual(state.videos.map(\.id), [b.id])
        XCTAssertEqual(state.playlists[0].items, [b.id])
        XCTAssertNil(state.playlists[0].wallpaperOptions[a.id.uuidString])
        XCTAssertEqual(state.playlists[0].options(for: b.id).zoom, 1.4)
        XCTAssertNil(state.config(for: "D1").content)
        XCTAssertNil(state.config(for: "D1").wallpaperOptions[a.id.uuidString])
        XCTAssertEqual(state.config(for: "D1").options(for: b.id).zoom, 0.5)
        XCTAssertEqual(state.config(for: "D2").content, .wallpaper(b.id))
        XCTAssertEqual(state.config(for: "D3").content, .playlist(playlist.id), "a playlist stays with what is left")
    }

    func testReplacingAnItemMovesItsPlacesAndSettings() {
        let old = VideoItem(path: "/L/1/scene.pkg", workshopID: "1"), other = VideoItem(path: "/b.mp4")
        let fresh = VideoItem(path: "/L/1/scene.pkg", workshopID: "1")
        var config = DisplayConfig(content: .wallpaper(old.id))
        config.wallpaperOptions[old.id.uuidString] = WallpaperOptions(zoom: 2)
        let playlist = Playlist(name: "P", items: [other.id, old.id],
                                wallpaperOptions: [old.id.uuidString: WallpaperOptions(zoom: 1.5)])
        var state = LibraryState(videos: [old, other], playlists: [playlist], displays: ["D1": config])
        state.replace(old.id, with: fresh)
        XCTAssertEqual(state.videos.map(\.id), [fresh.id, other.id])
        XCTAssertEqual(state.playlists[0].items, [other.id, fresh.id])
        XCTAssertEqual(state.playlists[0].options(for: fresh.id).zoom, 1.5)
        XCTAssertEqual(state.config(for: "D1").content, .wallpaper(fresh.id))
        XCTAssertEqual(state.config(for: "D1").options(for: fresh.id).zoom, 2)
        XCTAssertNil(state.config(for: "D1").wallpaperOptions[old.id.uuidString])
    }

    func testDeletingAPlaylistTakesItOffItsDisplays() {
        let a = VideoItem(path: "/a.mp4")
        let keep = Playlist(name: "Keep", items: [a.id]), gone = Playlist(name: "Gone", items: [a.id])
        var state = LibraryState(videos: [a], playlists: [keep, gone],
                                 displays: ["D1": DisplayConfig(content: .playlist(gone.id)),
                                            "D2": DisplayConfig(content: .playlist(keep.id))])
        state.removePlaylist(gone.id)
        XCTAssertEqual(state.playlists.map(\.id), [keep.id])
        XCTAssertNil(state.config(for: "D1").content)
        XCTAssertEqual(state.config(for: "D2").content, .playlist(keep.id))
        XCTAssertEqual(state.videos, [a], "the wallpapers stay in the library")
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

    func testLineupFollowsTheDisplaysContentAndSkipsMissingIDs() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        let playlist = Playlist(name: "P", items: [b.id, UUID(), a.id])
        let state = LibraryState(videos: [a, b], playlists: [playlist],
                                 displays: ["D1": DisplayConfig(content: .playlist(playlist.id)),
                                            "D2": DisplayConfig(content: .wallpaper(a.id))])
        XCTAssertEqual(state.items(of: playlist).map(\.id), [b.id, a.id])
        XCTAssertEqual(state.lineup(on: "D1").map(\.id), [b.id, a.id])
        XCTAssertEqual(state.lineup(on: "D2").map(\.id), [a.id])
        XCTAssertEqual(state.lineup(on: "D3"), [])
        XCTAssertEqual(state.playlist(on: "D1")?.id, playlist.id)
        XCTAssertNil(state.playlist(on: "D2"))
    }

    func testAPlaylistsOwnOptionsApplyWhileADisplayPlaysIt() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        let playlist = Playlist(name: "P", items: [a.id],
                                wallpaperOptions: [a.id.uuidString: WallpaperOptions(volume: 0.2)])
        var config = DisplayConfig(content: .playlist(playlist.id))
        config.wallpaperOptions = [a.id.uuidString: WallpaperOptions(volume: 0.7), b.id.uuidString: WallpaperOptions(volume: 0.4)]
        var state = LibraryState(videos: [a, b], playlists: [playlist], displays: ["D1": config])
        XCTAssertEqual(state.options(for: a.id, on: "D1").volume, 0.2)
        XCTAssertEqual(state.options(for: b.id, on: "D1").volume, 0.4, "a wallpaper outside the playlist keeps the display's")
        state.setContent(.wallpaper(a.id), on: "D1")
        XCTAssertEqual(state.options(for: a.id, on: "D1").volume, 0.7, "on its own it has the display's options")
    }

    func testPlaylistTimingClampsAndDecodesWithDefaults() throws {
        let playlist = Playlist(name: "P", intervalValue: 0, intervalUnit: .seconds, transitionDuration: 60)
        XCTAssertEqual(playlist.intervalValue, 1, "the interval clamps to 1...999")
        XCTAssertEqual(playlist.intervalSeconds, Playlist.minimumInterval)
        XCTAssertTrue(playlist.intervalIsClamped)
        XCTAssertEqual(playlist.transitionDuration, Playlist.transitionDurations.upperBound)
        XCTAssertEqual(Playlist(name: "P", transition: .cut).transitionSeconds, 0, "a hard switch takes no time")
        let id = UUID()
        let decoded = try JSONDecoder().decode(Playlist.self, from: Data(#"{"id":"\#(id.uuidString)","name":"Old"}"#.utf8))
        XCTAssertEqual(decoded, Playlist(id: id, name: "Old"))
        XCTAssertEqual(decoded.intervalSeconds, 300)
        XCTAssertNil(decoded.imageURL)
    }

    func testAgentRecordFromAnOlderVersionDecodes() throws {
        let record = try JSONDecoder().decode(
            AgentRecord.self, from: Data(#"{"wantsRunning":true,"aerialSlots":["a.mov"],"legacyImported":true}"#.utf8))
        XCTAssertEqual(record, AgentRecord(aerialSlots: ["a.mov"]))
    }

    func testContentStampFollowsTheFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wm-\(UUID().uuidString).pkg")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("one".utf8).write(to: file)
        let item = VideoItem(path: file.path)
        let first = item.contentStamp
        XCTAssertEqual(item.contentStamp, first)
        try Data("longer content".utf8).write(to: file)
        XCTAssertNotEqual(item.contentStamp, first)
    }
}
