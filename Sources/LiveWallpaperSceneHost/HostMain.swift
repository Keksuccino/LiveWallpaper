import AppKit
import Darwin
import Core
import SceneFormat
import SceneEngine

// Owner: SCENERENDER. Entry point and IPC of the scene host (LiveWallpaperSceneHost.app, nested next to the agent).
// The host is started by the agent only while a scene needs it, answers the agent's HostCommands with HostStatuses
// (Core/HostIPC.swift), and exits when the agent is gone, when it is told to quit, or after being idle.
// Behaviour and lifecycle: SPEC3.md sections 1.2 to 1.6 and 3.5.
//
// Command line (for testing on a real Mac, SPEC3.md section 8.3):
//   LiveWallpaperSceneHost --probe <scene.pkg> [--assets <folder>]    prints the scene analysis as JSON and exits

@main
enum HostEntry {
    @MainActor static func main() {
        if let code = ProbeCommand.runIfRequested(CommandLine.arguments) { exit(code) }
        let app = NSApplication.shared
        let delegate = HostDelegate()
        app.delegate = delegate  // NSApplication keeps its delegate weakly
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum ProbeCommand {
    /// nil when `--probe` is not among the arguments.
    static func runIfRequested(_ arguments: [String]) -> Int32? {
        guard let index = arguments.firstIndex(of: "--probe"), index + 1 < arguments.count else { return nil }
        let scene = URL(fileURLWithPath: arguments[index + 1])
        var assets: URL?
        if let flag = arguments.firstIndex(of: "--assets"), flag + 1 < arguments.count {
            assets = URL(fileURLWithPath: arguments[flag + 1])
        }
        do {
            let loaded = try SceneLoader.load(packageAt: scene, sharedAssets: assets)
            let analysis = loaded.analysis
            let report: [String: Any] = [
                "support": analysis.support.rawValue,
                "notes": analysis.notes,
                "used": analysis.used.map(\.rawValue).sorted(),
                "unsupported": analysis.unsupported.map(\.rawValue).sorted(),
                "design": "\(analysis.designWidth)x\(analysis.designHeight)",
                "objects": loaded.document.objects.count,
                "needsSharedAssets": analysis.needsSharedAssets,
            ]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return 0
        } catch {
            FileHandle.standardError.write(Data("probe failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}

@MainActor final class HostDelegate: NSObject, NSApplicationDelegate {
    // Property defaults, not an `override init()` (SPEC2.md 9.1: that init is nonisolated on Swift 5.10).
    private let endpoint = HostEndpoint()
    private let player = ScenePlayer()
    private var recentCommandIDs: [String] = []
    private var statusSequence = 0
    private var agentPID: Int32 = 0
    private var watchdog: Timer?
    private var idleSince: Date? = Date()
    private var jobID: String?
    private var jobState: HostStatus.JobState = .idle
    private var jobProgress = 0.0
    private var jobMessage: String?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignals()
        player.onChange = { [weak self] _, _ in self?.postStatus(reply: nil) }
        endpoint.onCommand = { [weak self] command in self?.handle(command) }
        endpoint.startListening()
        startWatchdog()
        postStatus(reply: nil)   // the hello: the agent waits for the first status before it sends work
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        player.hide()
        postStatus(reply: nil, quitting: true)
        return .terminateNow
    }

    // MARK: Commands

    private func handle(_ command: HostCommand) {
        if command.agentPID > 0 { agentPID = command.agentPID }
        guard !recentCommandIDs.contains(command.id) else {
            postStatus(reply: command.id)   // a retransmit is answered, not executed twice
            return
        }
        recentCommandIDs.append(command.id)
        if recentCommandIDs.count > 32 { recentCommandIDs.removeFirst() }
        switch command.kind {
        case .ping:
            break
        case .showScene:
            if let id = command.itemID, let path = command.scenePath {
                player.show(itemID: id, scenePath: URL(fileURLWithPath: path),
                            previewPath: command.previewPath.map { URL(fileURLWithPath: $0) },
                            assetsPath: command.assetsPath.map { URL(fileURLWithPath: $0) },
                            fpsCap: command.fpsCap ?? 30)
            }
        case .hideScene:
            player.hide()
        case .setPaused:
            player.setPaused(command.paused ?? false)
        case .setMuted:
            player.setMuted(command.muted ?? true)
        case .renderLock:
            // SCENERENDER: run LockVideoRenderer.render on a utility-priority Task, keep the Task handle for
            // cancelRender, and report progress through postStatus. The stub fails at once.
            jobID = command.jobID
            jobState = .failed
            jobProgress = 0
            jobMessage = "Lock screen rendering is not implemented yet."
        case .cancelRender:
            if jobID == command.jobID, jobState == .rendering { jobState = .cancelled }
        case .quit:
            postStatus(reply: command.id)
            NSApp.terminate(nil)
            return
        }
        idleSince = player.state == .none && jobState != .rendering ? Date() : nil
        postStatus(reply: command.id)
    }

    private func postStatus(reply: String?, quitting: Bool = false) {
        statusSequence += 1
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        endpoint.post(HostStatus(seq: statusSequence, reply: reply, pid: ProcessInfo.processInfo.processIdentifier,
                                 hostVersion: version, sceneItemID: player.itemID, sceneState: player.state,
                                 sceneMessage: nil, jobID: jobID, jobState: jobState, jobProgress: jobProgress,
                                 jobMessage: jobMessage, residentMB: 0, quitting: quitting))
    }

    // MARK: Lifetime

    /// Exits when the agent is gone, or when nothing has been asked of the host for 15 s.
    private func startWatchdog() {
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.checkAlive() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func checkAlive() {
        if agentPID > 0, kill(agentPID, 0) != 0, errno == ESRCH {
            NSApp.terminate(nil)
            return
        }
        if let idleSince, Date().timeIntervalSince(idleSince) > 15 { NSApp.terminate(nil) }
    }

    private func installTerminationSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { Task { @MainActor in NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }
}
