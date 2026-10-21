import Foundation

// Wallpaper agent <-> scene host (LiveWallpaperSceneHost.app), over DistributedNotificationCenter, in the same
// style as IPC.swift: one command name (agent -> host), one status name (host -> agent), property-list payloads,
// idempotent commands answered by a status whose `reply` is the command id, `.deliverImmediately` everywhere.
// Both sides live in the same bundle, so the version only guards against an old host surviving an update.
// The agent links this file (Core) but never SceneFormat or SceneEngine (SPEC3.md section 1).

public enum HostIPC {
    public static let version = 1
    public static let bundleID = "com.noob3301.LiveWallpaper.scenehost"
    public static let bundleName = "LiveWallpaperSceneHost.app"
    /// Info.plist LWRole value of the host.
    public static let role = "scenehost"
    public static let commandName = Notification.Name("com.noob3301.LiveWallpaper.host.command.v1")
    public static let statusName = Notification.Name("com.noob3301.LiveWallpaper.host.status.v1")
}

// MARK: - Commands (agent -> host)

public struct HostCommand: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case ping           // answer with a status (the agent's way to learn that the host is up)
        case showScene      // play `scenePath` on the desktop windows (replaces a running scene)
        case hideScene      // close the desktop windows, release GPU resources; the host stays up
        case setPaused      // `paused`
        case setMuted       // `muted` (M0 has no audio; the flag is stored for M3)
        case renderLock     // offline-render the lock screen loop (one job at a time; a new one replaces a queued one)
        case cancelRender   // abort job `jobID`
        case quit           // close everything and exit
    }

    public var id: String                  // correlation id; retransmits reuse it and are executed once
    public var kind: Kind
    public var agentPID: Int32             // sender; the host exits when this process is gone
    public var itemID: UUID?               // showScene / renderLock: the library item
    public var scenePath: String?          // showScene / renderLock: VideoItem.path (scene.pkg or scene.json)
    public var previewPath: String?        // fallback still for previewOnly scenes and load failures
    public var assetsPath: String?         // shared assets folder if present
    public var muted: Bool?
    public var paused: Bool?
    public var fpsCap: Int?                // showScene: live frame cap (agent sends 30 on battery, 60 on power)
    public var sceneZoom: Double?          // showScene: the user's zoom (see LibraryState.sceneZoom)
    public var jobID: String?              // renderLock / cancelRender
    public var width: Int?                 // renderLock: output pixels
    public var height: Int?
    public var fps: Int?
    public var loopSeconds: Double?        // renderLock: nil = the engine decides (LoopPlan.chooseLoopSeconds)
    public var outputPath: String?         // renderLock: final .mov; the host writes <name>.partial.mov first

    public init(kind: Kind, agentPID: Int32 = ProcessInfo.processInfo.processIdentifier,
                itemID: UUID? = nil, scenePath: String? = nil, previewPath: String? = nil, assetsPath: String? = nil,
                muted: Bool? = nil, paused: Bool? = nil, fpsCap: Int? = nil, sceneZoom: Double? = nil,
                jobID: String? = nil, width: Int? = nil, height: Int? = nil, fps: Int? = nil,
                loopSeconds: Double? = nil, outputPath: String? = nil, id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
        self.agentPID = agentPID
        self.itemID = itemID
        self.scenePath = scenePath
        self.previewPath = previewPath
        self.assetsPath = assetsPath
        self.muted = muted
        self.paused = paused
        self.fpsCap = fpsCap
        self.sceneZoom = sceneZoom
        self.jobID = jobID
        self.width = width
        self.height = height
        self.fps = fps
        self.loopSeconds = loopSeconds
        self.outputPath = outputPath
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = ["v": HostIPC.version, "id": id, "cmd": kind.rawValue, "agent": Int(agentPID)]
        if let itemID { info["item"] = itemID.uuidString }
        if let scenePath { info["scene"] = scenePath }
        if let previewPath { info["preview"] = previewPath }
        if let assetsPath { info["assets"] = assetsPath }
        if let muted { info["muted"] = muted }
        if let paused { info["paused"] = paused }
        if let fpsCap { info["fpsCap"] = fpsCap }
        if let sceneZoom { info["zoom"] = sceneZoom }
        if let jobID { info["job"] = jobID }
        if let width { info["w"] = width }
        if let height { info["h"] = height }
        if let fps { info["fps"] = fps }
        if let loopSeconds { info["loop"] = loopSeconds }
        if let outputPath { info["out"] = outputPath }
        return info
    }

    /// nil for anything that is not a well-formed command of a known kind.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo,
              let id = info["id"] as? String,
              let raw = info["cmd"] as? String,
              let kind = Kind(rawValue: raw) else { return nil }
        self.id = id
        self.kind = kind
        self.agentPID = Int32(truncatingIfNeeded: info["agent"] as? Int ?? 0)
        self.itemID = (info["item"] as? String).flatMap { UUID(uuidString: $0) }
        self.scenePath = info["scene"] as? String
        self.previewPath = info["preview"] as? String
        self.assetsPath = info["assets"] as? String
        self.muted = info["muted"] as? Bool
        self.paused = info["paused"] as? Bool
        self.fpsCap = info["fpsCap"] as? Int
        self.sceneZoom = info["zoom"] as? Double
        self.jobID = info["job"] as? String
        self.width = info["w"] as? Int
        self.height = info["h"] as? Int
        self.fps = info["fps"] as? Int
        self.loopSeconds = info["loop"] as? Double
        self.outputPath = info["out"] as? String
    }
}

// MARK: - Status (host -> agent)

public struct HostStatus: Equatable, Sendable {
    /// What the desktop windows show.
    public enum SceneState: String, Sendable {
        case none            // no scene
        case loading         // parsing / uploading textures; the agent keeps its own windows up meanwhile
        case playing         // first frame presented: the agent may hide its own windows now
        case paused
        case fallbackStill   // showing the preview image (previewOnly scene or the scene failed to load)
        case failed          // nothing is shown; `sceneMessage` says why
    }

    /// The offline lock render job.
    public enum JobState: String, Sendable {
        case idle
        case rendering
        case finished        // `outputPath` of the command is complete and valid
        case failed
        case cancelled
    }

    public var seq: Int                    // increases with every post within one host process
    public var reply: String?              // id of the command this answers; nil for spontaneous posts
    public var pid: Int32
    public var hostVersion: String
    public var sceneItemID: UUID?
    public var sceneState: SceneState
    public var sceneMessage: String?
    public var jobID: String?
    public var jobState: JobState
    public var jobProgress: Double         // 0...1
    public var jobMessage: String?
    public var residentMB: Int             // physical footprint, for the measurements in SPEC3.md section 8
    public var quitting: Bool              // last post before the host terminates

    public init(seq: Int = 0, reply: String? = nil, pid: Int32 = 0, hostVersion: String = "",
                sceneItemID: UUID? = nil, sceneState: SceneState = .none, sceneMessage: String? = nil,
                jobID: String? = nil, jobState: JobState = .idle, jobProgress: Double = 0, jobMessage: String? = nil,
                residentMB: Int = 0, quitting: Bool = false) {
        self.seq = seq
        self.reply = reply
        self.pid = pid
        self.hostVersion = hostVersion
        self.sceneItemID = sceneItemID
        self.sceneState = sceneState
        self.sceneMessage = sceneMessage
        self.jobID = jobID
        self.jobState = jobState
        self.jobProgress = jobProgress
        self.jobMessage = jobMessage
        self.residentMB = residentMB
        self.quitting = quitting
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = [
            "v": HostIPC.version, "seq": seq, "pid": Int(pid), "version": hostVersion,
            "scene": sceneState.rawValue, "job": jobState.rawValue, "prog": jobProgress,
            "mb": residentMB, "quitting": quitting,
        ]
        if let reply { info["reply"] = reply }
        if let sceneItemID { info["item"] = sceneItemID.uuidString }
        if let sceneMessage { info["sceneMsg"] = sceneMessage }
        if let jobID { info["jobID"] = jobID }
        if let jobMessage { info["jobMsg"] = jobMessage }
        return info
    }

    /// nil for anything that is not a well-formed status.
    public init?(userInfo: [AnyHashable: Any]?) {
        guard let info = userInfo,
              let seq = info["seq"] as? Int,
              let pid = info["pid"] as? Int else { return nil }
        self.seq = seq
        self.reply = info["reply"] as? String
        self.pid = Int32(truncatingIfNeeded: pid)
        self.hostVersion = info["version"] as? String ?? ""
        self.sceneItemID = (info["item"] as? String).flatMap { UUID(uuidString: $0) }
        self.sceneState = (info["scene"] as? String).flatMap { SceneState(rawValue: $0) } ?? .none
        self.sceneMessage = info["sceneMsg"] as? String
        self.jobID = info["jobID"] as? String
        self.jobState = (info["job"] as? String).flatMap { JobState(rawValue: $0) } ?? .idle
        self.jobProgress = info["prog"] as? Double ?? 0
        self.jobMessage = info["jobMsg"] as? String
        self.residentMB = info["mb"] as? Int ?? 0
        self.quitting = info["quitting"] as? Bool ?? false
    }
}

// MARK: - Endpoints

/// Host side: listens for commands, posts statuses. Handlers run on the main actor.
public final class HostEndpoint: NSObject {
    public var onCommand: (@MainActor (HostCommand) -> Void)?
    private var listening = false

    public override init() {
        super.init()
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    /// Registers for commands; safe to call more than once.
    public func startListening() {
        guard !listening else { return }
        listening = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: HostIPC.commandName,
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    public func post(_ status: HostStatus) {
        DistributedNotificationCenter.default().postNotificationName(
            HostIPC.statusName, object: nil, userInfo: status.userInfo, deliverImmediately: true)
    }

    @objc private func received(_ note: Notification) {
        guard let command = HostCommand(userInfo: note.userInfo) else { return }
        let handler = onCommand
        Task { @MainActor in handler?(command) }
    }
}

/// Agent side: listens for host statuses, posts commands. Handlers run on the main actor.
public final class HostClientEndpoint: NSObject {
    public var onStatus: (@MainActor (HostStatus) -> Void)?
    private var listening = false

    public override init() {
        super.init()
    }

    deinit { DistributedNotificationCenter.default().removeObserver(self) }

    /// Registers for statuses; safe to call more than once.
    public func startListening() {
        guard !listening else { return }
        listening = true
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(received(_:)), name: HostIPC.statusName,
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    public func send(_ command: HostCommand) {
        DistributedNotificationCenter.default().postNotificationName(
            HostIPC.commandName, object: nil, userInfo: command.userInfo, deliverImmediately: true)
    }

    @objc private func received(_ note: Notification) {
        guard let status = HostStatus(userInfo: note.userInfo) else { return }
        let handler = onStatus
        Task { @MainActor in handler?(status) }
    }
}
