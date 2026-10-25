import XCTest
@testable import SceneFormat

// PKG/TEX/scene.json fixtures are built in memory by the tests; no Wallpaper Engine content in the repo.
final class LoopPlanTests: XCTestCase {
    func testSeamIsContinuous() {
        let plan = LoopPlan(loopSeconds: 20, crossfadeSeconds: 2, fps: 30)
        XCTAssertEqual(plan.loopFrames, 600)
        XCTAssertEqual(plan.crossfadeFrames, 60)
        XCTAssertEqual(plan.renderCalls, 660)
        let last = plan.source(forFrame: plan.loopFrames - 1)
        let first = plan.source(forFrame: 0)
        XCTAssertNil(last.secondary)
        // the frame after the last one (t = T) is exactly what frame 0 shows
        XCTAssertEqual(first.secondary ?? -1, plan.loopSeconds, accuracy: 1e-9)
        XCTAssertEqual(first.mix, 1, accuracy: 1e-6)
        XCTAssertEqual(last.primary + 1.0 / 30, plan.loopSeconds, accuracy: 1e-9)
    }

    func testCrossfadeEndsWhereThePlainFramesBegin() {
        let plan = LoopPlan(loopSeconds: 10, crossfadeSeconds: 1, fps: 30)
        let inside = plan.source(forFrame: plan.crossfadeFrames - 1)
        XCTAssertNotNil(inside.secondary)
        XCTAssertGreaterThan(inside.mix, 0)
        XCTAssertLessThan(inside.mix, 0.1)
        XCTAssertNil(plan.source(forFrame: plan.crossfadeFrames).secondary)
    }

    func testNoCrossfadeForPeriodicScenes() {
        let plan = LoopPlan.choose(scenePeriod: 4, fps: 30)
        XCTAssertEqual(plan.crossfadeFrames, 0)
        XCTAssertEqual(plan.loopSeconds, 12, accuracy: 1e-9)   // 3 repeats reach the 10 s minimum
        XCTAssertNil(plan.source(forFrame: 0).secondary)
    }

    func testDefaultsAndClamping() {
        let plan = LoopPlan.choose(scenePeriod: nil, fps: 30)
        XCTAssertEqual(plan.loopSeconds, 20, accuracy: 1e-9)
        XCTAssertEqual(plan.crossfadeSeconds, 2, accuracy: 1e-9)
        let tiny = LoopPlan(loopSeconds: 0.01, crossfadeSeconds: 5, fps: 30)
        XCTAssertGreaterThanOrEqual(tiny.loopFrames, 2)
        XCTAssertLessThanOrEqual(tiny.crossfadeFrames, tiny.loopFrames / 2)
        XCTAssertEqual(LoopPlan.choose(scenePeriod: 0.5, fps: 30).loopSeconds, 20, accuracy: 1e-9, "periods under 1 s are ignored")
    }
}
