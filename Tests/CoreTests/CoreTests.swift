import XCTest
@testable import Core

// Pure checks only: nothing here may touch ~/Library/Application Support (these run on developers' Macs too).
// Owner: scaffold. Workers may ADD tests in new files.
final class CoreTests: XCTestCase {
    private func decode(_ json: String) throws -> LibraryState {
        try JSONDecoder().decode(LibraryState.self, from: Data(json.utf8))
    }

    func testSchema1StateMigratesToSharedTargets() throws {
        let a = UUID(), b = UUID()
        let state = try decode("""
        {"schema":1,"revision":7,
         "videos":[{"id":"\(a.uuidString)","path":"/v/a.mp4"},{"id":"\(b.uuidString)","path":"/v/b.mov"}],
         "selectedID":"\(b.uuidString)","rotateEnabled":false,"intervalValue":7,"intervalUnit":"hours",
         "applyToDesktop":true,"applyToLockScreen":false}
        """)
        XCTAssertEqual(state.schema, 2)
        XCTAssertEqual(state.revision, 7)
        XCTAssertTrue(state.sameForBoth)
        XCTAssertTrue(state.muted)
        XCTAssertEqual(state.desktop.selectedID, b)
        XCTAssertFalse(state.desktop.rotateEnabled)
        XCTAssertEqual(state.desktop.intervalValue, 7)
        XCTAssertEqual(state.desktop.intervalUnit, .hours)
        XCTAssertTrue(state.desktop.enabled)
        XCTAssertFalse(state.lock.enabled)
        XCTAssertEqual(state.config(for: .lock).selectedID, b)
        XCTAssertEqual(state.videos.map(\.id), [a, b])
        XCTAssertFalse(state.canPlay(.lock))
        XCTAssertTrue(state.canPlay(.desktop))
    }

    func testPhase1RecordWithoutSchemaKeyDecodes() throws {
        let state = try decode(#"{"videos":[],"rotateEnabled":true,"intervalValue":0,"intervalUnit":"seconds"}"#)
        XCTAssertEqual(state.schema, 2)
        XCTAssertEqual(state.desktop.intervalValue, 1, "interval clamps to 1...999")
    }

    func testSchema2RoundTripKeepsEverything() throws {
        let item = VideoItem(path: "/L/1/scene.pkg", title: "T", workshopID: "1",
                             scene: SceneInfo(support: .partial, notes: ["Particles are not supported yet."]))
        var state = LibraryState(videos: [item], muted: false, sameForBoth: false,
                                 desktop: TargetConfig(enabled: true, selectedID: item.id),
                                 lock: TargetConfig(enabled: true, selectedID: nil, rotateEnabled: false))
        state.revision = 3
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(LibraryState.self, from: data)
        XCTAssertEqual(back, state)
        XCTAssertEqual(back.videos[0].kind, .scene)
        XCTAssertFalse(back.muted)
        XCTAssertFalse(back.lock.rotateEnabled)
    }

    func testAssignToOneTargetTurnsSameForBothOffAndKeepsTheOther() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        var state = LibraryState(videos: [a, b], desktop: TargetConfig(selectedID: a.id))
        state.normalize()
        state.assign(b.id, to: [.lock])
        XCTAssertFalse(state.sameForBoth)
        XCTAssertEqual(state.config(for: .desktop).selectedID, a.id)
        XCTAssertEqual(state.config(for: .lock).selectedID, b.id)
        XCTAssertEqual(state.targets(of: b.id), [.lock])
        state.assign(b.id, to: [.desktop, .lock])
        XCTAssertEqual(state.targets(of: b.id), [.desktop, .lock])
        XCTAssertFalse(state.sameForBoth, "assigning to both leaves the switch alone")
    }

    func testSameForBothMirrorsEverythingButEnabled() {
        let a = VideoItem(path: "/a.mp4")
        var state = LibraryState(videos: [a], desktop: TargetConfig(selectedID: a.id, intervalValue: 9),
                                 lock: TargetConfig(enabled: false))
        state.normalize()
        XCTAssertEqual(state.lock.selectedID, a.id)
        XCTAssertEqual(state.lock.intervalValue, 9)
        XCTAssertFalse(state.lock.enabled)
        XCTAssertTrue(state.canStart)
        state.selectedID = nil   // phase-2 accessor writes both while sameForBoth
        XCTAssertNil(state.lock.selectedID)
    }

    func testPlaylistFiltersMissingIDs() {
        let a = VideoItem(path: "/a.mp4"), b = VideoItem(path: "/b.mp4")
        let state = LibraryState(videos: [a, b], desktop: TargetConfig(playlist: [b.id, UUID()]))
        XCTAssertEqual(state.items(for: .desktop).map(\.id), [b.id])
        XCTAssertFalse(state.hasMultipleItems(.desktop))
    }

    func testLockRenderCacheValidity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lw-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pkg = folder.appendingPathComponent("scene.pkg")
        try Data("pkg".utf8).write(to: pkg)
        let item = VideoItem(path: pkg.path, workshopID: "9", scene: SceneInfo(support: .full))
        XCTAssertFalse(LockRenderCache.isValid(for: item, width: 3024, height: 1964))
        try Data("mov".utf8).write(to: LockRenderCache.videoURL(for: item, width: 3024, height: 1964))
        XCTAssertFalse(LockRenderCache.isValid(for: item, width: 3024, height: 1964), "no metadata yet")
        let meta = LockRenderCache.Meta(width: 3024, height: 1964, fps: 30, loopSeconds: 20,
                                        sourceStamp: LockRenderCache.sourceStamp(for: item))
        try LockRenderCache.writeMeta(meta, for: item)
        XCTAssertTrue(LockRenderCache.isValid(for: item, width: 3024, height: 1964))
        XCTAssertFalse(LockRenderCache.isValid(for: item, width: 1920, height: 1080), "other size")
        var stale = meta
        stale.engineRevision = LockRenderCache.engineRevision + 1
        try LockRenderCache.writeMeta(stale, for: item)
        XCTAssertFalse(LockRenderCache.isValid(for: item, width: 3024, height: 1964), "engine revision changed")
        LockRenderCache.removeStale(for: item, keepingWidth: 1920, height: 1080)
        XCTAssertFalse(FileManager.default.fileExists(atPath: LockRenderCache.videoURL(for: item, width: 3024, height: 1964).path))
    }

    func testIPCRoundTrips() {
        let id = UUID(), lock = UUID()
        let command = AgentCommand(kind: .play, videoID: id, revision: 4, target: .lock)
        XCTAssertEqual(AgentCommand(userInfo: command.userInfo as [AnyHashable: Any]), command)
        let status = AgentStatus(seq: 2, reply: command.id, pid: 9, agentVersion: "3.0", isRunning: true,
                                 currentID: id, stateRevision: 4, lockID: lock, muted: false, sceneHostRunning: true,
                                 lockRender: LockRenderStatus(itemID: lock, state: .rendering, progress: 0.4))
        XCTAssertEqual(AgentStatus(userInfo: status.userInfo as [AnyHashable: Any]), status)
        let host = HostCommand(kind: .renderLock, agentPID: 11, itemID: id, scenePath: "/s.pkg", jobID: "j",
                               width: 3024, height: 1964, fps: 30, loopSeconds: 20, outputPath: "/o.mov")
        XCTAssertEqual(HostCommand(userInfo: host.userInfo as [AnyHashable: Any]), host)
        let hostStatus = HostStatus(seq: 1, pid: 5, sceneItemID: id, sceneState: .playing, jobID: "j",
                                    jobState: .rendering, jobProgress: 0.5, residentMB: 321)
        XCTAssertEqual(HostStatus(userInfo: hostStatus.userInfo as [AnyHashable: Any]), hostStatus)
    }
}
