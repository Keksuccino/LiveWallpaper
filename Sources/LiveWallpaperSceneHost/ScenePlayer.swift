import AppKit
import Core
import SceneFormat
import SceneEngine

// Owner: SCENERENDER. The live desktop player of the scene host: one borderless window per screen at the same
// level as the agent's video windows (desktop window level + 1, all Spaces, ignores mouse), each with a
// CAMetalLayer that a SceneRenderer draws into. Frame pump: a timer at `fpsCap`, stopped while the desktop is
// covered (occlusion), paused by the user, or the display sleeps. Pointer position for parallax comes from
// NSEvent.mouseLocation (no permission needed). Contract with HostMain: SPEC3.md section 3.5.

@MainActor final class ScenePlayer {
    /// Called when the state changes (HostMain turns it into a HostStatus).
    var onChange: (@MainActor (HostStatus.SceneState, String?) -> Void)?
    private(set) var state: HostStatus.SceneState = .none
    private(set) var itemID: UUID?

    init() {}

    /// Loads the scene (SceneLoader), builds renderers, opens the windows and starts the pump. Reports `.loading`,
    /// then `.playing` after the first frame was presented; `.fallbackStill` when only the preview image can be
    /// shown (analysis.support == .previewOnly, or a load/shader/texture error); `.failed` when not even that works.
    func show(itemID: UUID, scenePath: URL, previewPath: URL?, assetsPath: URL?, fpsCap: Int) {
        self.itemID = itemID
        state = .failed
        onChange?(state, "Scene playback is not implemented yet.")
    }

    /// Closes the windows, drops every GPU resource, stops the pump.
    func hide() {
        itemID = nil
        state = .none
        onChange?(state, nil)
    }

    func setPaused(_ paused: Bool) {}
    func setMuted(_ muted: Bool) {}
    func setFPSCap(_ fps: Int) {}
}
