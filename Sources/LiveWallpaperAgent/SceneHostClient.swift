import AppKit
import Core

// Owner: AGENT. The agent's side of the scene host (SPEC3.md sections 1.2 to 1.6): launches
// LiveWallpaperSceneHost.app only when a scene needs it, talks to it with HostCommand/HostStatus (Core), notices
// when it dies, and never imports SceneFormat or SceneEngine (build.sh fails the build if the agent links them).
// This file is a stub with the final signatures; the behaviour to implement is listed on each member.

@MainActor final class SceneHostClient {
    /// Every host status (also the hello). The Orchestrator reacts to scene/job state changes.
    var onStatus: (@MainActor (HostStatus) -> Void)?
    /// The host process ended. `unexpectedly` = nobody asked it to quit (crash, kill, jetsam).
    var onTerminated: (@MainActor (_ unexpectedly: Bool) -> Void)?

    /// A host process exists (launched by us or found running).
    private(set) var isRunning = false
    /// The host answered at least once since it was launched: commands go out immediately.
    private(set) var isReady = false
    private(set) var lastStatus: HostStatus?

    private let endpoint = HostClientEndpoint()

    init() {}

    /// <agent>.app/Contents/Library/LoginItems/ is the folder of both helpers: the host sits next to the agent.
    static var hostAppURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(HostIPC.bundleName, isDirectory: true)
    }

    /// True when a process with the host's bundle id exists.
    static func hostProcessExists() -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: HostIPC.bundleID).contains { !$0.isTerminated }
    }

    /// Launches the host if it is not running (NSWorkspace.openApplication with activates = false), starts listening
    /// for its statuses and sends `.ping` until the first status arrives (hello timeout 10 s -> onTerminated(true)).
    func start() {}

    /// Sends now when `isReady`, else queues until the hello arrives and calls `start()` if needed. The command is
    /// retransmitted (same id) after 1.5 s and 3 s until a status with `reply == id` arrives; none after 4.5 s means
    /// the host is unresponsive: terminate it and report onTerminated(true).
    func send(_ command: HostCommand) {}

    /// Asks the host to quit (`.quit`), force-terminates it after 2 s, forgets queued commands. Idempotent.
    func shutdown() {}
}
