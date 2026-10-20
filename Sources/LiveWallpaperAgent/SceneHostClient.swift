import AppKit
import Core

// The agent's side of the scene host (SPEC3.md sections 1.2 to 1.6): launches LiveWallpaperSceneHost.app only when a
// scene needs it, talks to it with HostCommand/HostStatus (Core), notices when it dies, and never imports
// SceneFormat or SceneEngine (build.sh fails the build if the agent links them). Transport only: what to do after
// a crash (back-off, skipping a scene) is the Orchestrator's decision.

@MainActor final class SceneHostClient {
    private static let helloTimeout: TimeInterval = 10
    private static let retransmitAges: [TimeInterval] = [1.5, 3]
    private static let unresponsiveAge: TimeInterval = 4.5
    private static let forceKillDelay: UInt64 = 2_000_000_000

    private struct Pending {
        var command: HostCommand
        var sentAt: Date
        var retransmits = 0
    }

    /// Every host status that is not older than the last one (also the hello).
    var onStatus: (@MainActor (HostStatus) -> Void)?
    /// The host process ended. `unexpectedly` = nobody asked it to quit (crash, kill, jetsam, no hello, no answer).
    var onTerminated: (@MainActor (_ unexpectedly: Bool) -> Void)?
    /// shutdown() finished: the process is gone (or was force-terminated).
    var onExited: (@MainActor () -> Void)?

    /// A host process exists (launched by us or found running).
    private(set) var isRunning = false
    /// The host answered at least once since it was launched: commands go out immediately.
    private(set) var isReady = false
    /// shutdown() was called and the process has not ended yet.
    private(set) var isExiting = false
    private(set) var lastStatus: HostStatus?

    private let endpoint = HostClientEndpoint()
    private var queue: [HostCommand] = []
    private var pending: [String: Pending] = [:]
    private var hostPID: Int32?
    private var launchedAt = Date()
    private var lastPing = Date.distantPast
    private var expectedExit = false
    private var staleRestart = false
    private var tickTask: Task<Void, Never>?
    private var terminationObserver: NSObjectProtocol?

    init() {}

    /// <agent>.app/Contents/Library/LoginItems/ is the folder of both helpers: the host sits next to the agent.
    static var hostAppURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent(HostIPC.bundleName, isDirectory: true)
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: hostAppURL.path) }

    /// True when a process with the host's bundle id exists.
    static func hostProcessExists() -> Bool { !runningHosts().isEmpty }

    private static func runningHosts() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: HostIPC.bundleID).filter { !$0.isTerminated }
    }

    /// Launches the host if it is not running (a process left over from an earlier agent is adopted), listens for
    /// its statuses and pings every second until the first one arrives (hello timeout 10 s -> onTerminated(true)).
    func start() {
        guard !isRunning, !isExiting else { return }
        isRunning = true
        isReady = false
        expectedExit = false
        hostPID = nil
        lastStatus = nil
        launchedAt = Date()
        lastPing = .distantPast
        endpoint.onStatus = { [weak self] status in self?.received(status) }
        endpoint.startListening()
        observeTermination()
        if let existing = Self.runningHosts().first {
            hostPID = existing.processIdentifier
        } else {
            launch()
        }
        armTick()
    }

    /// Sends now when `isReady`, else queues until the hello arrives (starting the host for work that needs one;
    /// the others are meaningless without a host and are dropped). The command is retransmitted (same id) after
    /// 1.5 s and 3 s until a status with `reply == id` arrives; none after 4.5 s means the host is unresponsive:
    /// it is terminated and onTerminated(true) fires.
    func send(_ command: HostCommand) {
        if !isRunning {
            guard command.kind == .showScene || command.kind == .renderLock else { return }
            start()
        }
        if isReady, !isExiting { transmit(command) } else { enqueue(command) }
    }

    /// Asks the host to quit (`.quit`), force-terminates it after 2 s, forgets queued commands. Idempotent.
    /// Commands sent afterwards wait for the old process to end and then start a new host.
    func shutdown() {
        queue.removeAll()
        guard isRunning, !isExiting else { return }
        isExiting = true
        expectedExit = true
        endpoint.send(HostCommand(kind: .quit))
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.forceKillDelay)
            guard let self, self.isExiting else { return }
            Self.forceTerminate(Self.runningHosts().map(\.processIdentifier))
            self.hostEnded()
        }
    }

    // MARK: Transport

    private func transmit(_ command: HostCommand) {
        endpoint.send(command)
        pending[command.id] = Pending(command: command, sentAt: Date())
        armTick()
    }

    private func enqueue(_ command: HostCommand) {
        switch command.kind {
        case .cancelRender:
            // Nothing to cancel on a host that never got the job.
            queue.removeAll { $0.kind == .renderLock && $0.jobID == command.jobID }
            return
        case .showScene, .hideScene:
            queue.removeAll { $0.kind == .showScene || $0.kind == .hideScene }
        case .renderLock, .setPaused, .setMuted:
            queue.removeAll { $0.kind == command.kind }
        case .ping, .quit:
            return
        }
        queue.append(command)
    }

    private func received(_ status: HostStatus) {
        guard isRunning else { return }
        if let reply = status.reply { pending[reply] = nil }
        if let last = lastStatus, last.pid == status.pid, status.seq <= last.seq { return }
        lastStatus = status
        hostPID = status.pid
        if status.quitting { expectedExit = true }
        if !isReady {
            let mine = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            if !mine.isEmpty, !status.hostVersion.isEmpty, status.hostVersion != mine {
                replaceStaleHost()  // a host that survived an update
                return
            }
            isReady = true
            let queued = queue
            queue.removeAll()
            queued.forEach(transmit)
        }
        onStatus?(status)
    }

    // One tick every 0.5 s while something waits for the host: pings before the hello, retransmits and the
    // unresponsive check afterwards. Returns false (and ends the loop) when there is nothing left to wait for.
    private func armTick() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled, let self, self.tick(Date()) else { return }
            }
        }
    }

    private func tick(_ now: Date) -> Bool {
        guard isRunning, !isExiting else {
            tickTask = nil
            return false
        }
        if !isReady {
            if now.timeIntervalSince(launchedAt) > Self.helloTimeout {
                unresponsive()
                return false
            }
            if now.timeIntervalSince(lastPing) >= 1 {
                lastPing = now
                endpoint.send(HostCommand(kind: .ping))
            }
            return true
        }
        for (id, entry) in pending {
            let age = now.timeIntervalSince(entry.sentAt)
            if age >= Self.unresponsiveAge {
                unresponsive()
                return false
            }
            if entry.retransmits < Self.retransmitAges.count, age >= Self.retransmitAges[entry.retransmits] {
                endpoint.send(entry.command)
                pending[id]?.retransmits += 1
            }
        }
        if pending.isEmpty {
            tickTask = nil
            return false
        }
        return true
    }

    // MARK: Process

    private func launch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: Self.hostAppURL, configuration: configuration) { [weak self] app, error in
            let pid = app?.processIdentifier
            let failed = error != nil
            Task { @MainActor [weak self] in self?.launched(pid: pid, failed: failed) }
        }
    }

    private func launched(pid: Int32?, failed: Bool) {
        guard isRunning else { return }
        if failed {
            hostEnded()
        } else if hostPID == nil {
            hostPID = pid
        }
    }

    private func observeTermination() {
        guard terminationObserver == nil else { return }
        let appKey = NSWorkspace.applicationUserInfoKey
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[appKey] as? NSRunningApplication
            let bundleID = app?.bundleIdentifier
            let pid = app?.processIdentifier
            Task { @MainActor [weak self] in self?.workspaceReportsTermination(bundleID: bundleID, pid: pid) }
        }
    }

    private func workspaceReportsTermination(bundleID: String?, pid: Int32?) {
        guard isRunning, bundleID == HostIPC.bundleID else { return }
        // The end of an earlier host (killed after a missing hello) must not count against the current one.
        if let pid, let hostPID, pid != hostPID { return }
        hostEnded()
    }

    private func hostEnded() {
        let expected = expectedExit
        let relaunch = staleRestart || (isExiting && !queue.isEmpty)
        let wasExiting = isExiting
        isRunning = false
        isReady = false
        isExiting = false
        expectedExit = false
        staleRestart = false
        hostPID = nil
        lastStatus = nil
        pending.removeAll()
        tickTask?.cancel()
        tickTask = nil
        if relaunch {
            start()  // the queue stays and goes out with the hello
            return
        }
        if !expected { queue.removeAll() }  // the Orchestrator re-sends what it still wants
        if wasExiting {
            onExited?()
            onExited = nil
        }
        onTerminated?(!expected)
    }

    private func replaceStaleHost() {
        staleRestart = true
        expectedExit = true
        Self.terminate(Self.runningHosts())
    }

    // Host that does not answer: ask it to end, force it later, and report it as crashed.
    private func unresponsive() {
        Self.terminate(Self.runningHosts())
        expectedExit = false
        hostEnded()
    }

    private static func terminate(_ apps: [NSRunningApplication]) {
        let pids = apps.map(\.processIdentifier)
        apps.forEach { $0.terminate() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: forceKillDelay)
            forceTerminate(pids)
        }
    }

    // Only the processes that were asked, never a host started since.
    private static func forceTerminate(_ pids: [Int32]) {
        runningHosts().filter { pids.contains($0.processIdentifier) }.forEach { $0.forceTerminate() }
    }
}
