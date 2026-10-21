import Foundation

// Settings app <-> wallpaper agent, over DistributedNotificationCenter.
//   Settings -> agent: one notification name (`commandName`), payload = AgentCommand.
//   agent -> Settings: one notification name (`statusName`),  payload = AgentStatus.
// Payloads are property lists of small scalars. Delivery is best effort (nothing is queued for a process that
// is not listening yet), so every command is idempotent and answered by a status whose `reply` is the command id.
// `.deliverImmediately` is required: without it a background process is sent these notifications late
// (phase 1 learned this with the lock/unlock notifications).

public enum IPC {
    /// Payload version ("v" key). 2 = per-target commands and status fields (additive over 1: the notification
    /// names stay ".v1" and receivers ignore keys they do not know; see SPEC3.md section 3.2).
    public static let version = 2
    public static let settingsBundleID = "com.noob3301.LiveWallpaper"
    public static let agentBundleID = "com.noob3301.LiveWallpaper.agent"
    /// Info.plist key that tells the two apps (and the phase-1 app, which lacks it) apart: "settings" or "agent".
    public static let roleKey = "LWRole"
    // The major protocol version is part of the name; an incompatible future protocol simply uses ".v2".
    public static let commandName = Notification.Name("com.noob3301.LiveWallpaper.ipc.command.v1")
    public static let statusName = Notification.Name("com.noob3301.LiveWallpaper.ipc.status.v1")
}

// MARK: - Commands (Settings -> agent)

public struct AgentCommand: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case ping      // answer with a status
        case start     // begin at `videoID`, else state.selectedID, else the first video
        case stop      // stop and restore Apple's wallpapers; the agent stays alive
        case pause
        case resume
        case next
        case play      // `videoID`: jump to it, starting playback if needed (on `target`, nil = both targets)
        case reload    // state.json changed; `revision` is what Settings just wrote
        case quit      // stop, restore, terminate the agent
    }

    public var id: String             // correlation id, echoed in AgentStatus.reply; also de-duplicates retransmits
    public var kind: Kind
    public var videoID: UUID?
    public var revision: Int?
    /// v2: which target `play` and `next` apply to; nil = both (the phase-2 behaviour).
    public var target: WallpaperTarget?

    public init(kind: Kind, videoID: UUID? = nil, revision: Int? = nil, target: WallpaperTarget? = nil,
                id: String = UUID().uuidString) {
        self.id = id
        self.kind = kind
        self.videoID = videoID
        self.revision = revision
        self.target = target
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = ["v": IPC.version, "id": id, "cmd": kind.rawValue]
        if let videoID { info["video"] = videoID.uuidString }
        if let revision { info["rev"] = revision }
        if let target { info["target"] = target.rawValue }
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
        self.videoID = (info["video"] as? String).flatMap { UUID(uuidString: $0) }
        self.revision = info["rev"] as? Int
        self.target = (info["target"] as? String).flatMap { WallpaperTarget(rawValue: $0) }
    }
}

// MARK: - Status (agent -> Settings)

/// The pre-rendered lock screen video of a scene (SPEC3.md section 1.5). At most one is reported at a time.
public struct LockRenderStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        case queued, rendering, finished, failed
    }

    public var itemID: UUID
    public var state: State
    public var progress: Double          // 0...1, meaningful while rendering
    public var message: String?          // user-facing reason when failed

    public init(itemID: UUID, state: State, progress: Double = 0, message: String? = nil) {
        self.itemID = itemID
        self.state = state
        self.progress = progress
        self.message = message
    }
}

public struct AgentStatus: Equatable, Sendable {
    public var seq: Int                 // increases with every post within one agent process
    public var reply: String?           // id of the command this answers; nil for spontaneous posts
    public var pid: Int32               // agent process id; a new pid means a new agent run (seq restarts)
    public var agentVersion: String
    public var isRunning: Bool
    public var isPaused: Bool
    public var currentID: UUID?
    public var failedIDs: [UUID]
    public var message: String?         // user-facing problem, nil when fine
    public var lockBusy: Bool           // the lock screen video is being prepared
    public var stateRevision: Int       // state.json revision the agent has applied
    public var quitting: Bool           // last post before the agent terminates
    // v2 additions. `currentID` is the DESKTOP item; `lockID` is the lock screen item.
    public var lockID: UUID?
    public var muted: Bool
    public var sceneHostRunning: Bool
    public var lockRender: LockRenderStatus?

    public init(seq: Int = 0, reply: String? = nil, pid: Int32 = 0, agentVersion: String = "",
                isRunning: Bool = false, isPaused: Bool = false, currentID: UUID? = nil,
                failedIDs: [UUID] = [], message: String? = nil, lockBusy: Bool = false,
                stateRevision: Int = 0, quitting: Bool = false,
                lockID: UUID? = nil, muted: Bool = true, sceneHostRunning: Bool = false,
                lockRender: LockRenderStatus? = nil) {
        self.seq = seq
        self.reply = reply
        self.pid = pid
        self.agentVersion = agentVersion
        self.isRunning = isRunning
        self.isPaused = isPaused
        self.currentID = currentID
        self.failedIDs = failedIDs
        self.message = message
        self.lockBusy = lockBusy
        self.stateRevision = stateRevision
        self.quitting = quitting
        self.lockID = lockID
        self.muted = muted
        self.sceneHostRunning = sceneHostRunning
        self.lockRender = lockRender
    }

    public var userInfo: [String: Any] {
        var info: [String: Any] = [
            "v": IPC.version, "seq": seq, "pid": Int(pid), "version": agentVersion,
            "running": isRunning, "paused": isPaused, "failed": failedIDs.map(\.uuidString),
            "lockBusy": lockBusy, "rev": stateRevision, "quitting": quitting,
            "muted": muted, "host": sceneHostRunning,
        ]
        if let lockID { info["lockCur"] = lockID.uuidString }
        if let lockRender {
            info["lrItem"] = lockRender.itemID.uuidString
            info["lrState"] = lockRender.state.rawValue
            info["lrProg"] = lockRender.progress
            if let message = lockRender.message { info["lrMsg"] = message }
        }
        if let reply { info["reply"] = reply }
        if let currentID { info["current"] = currentID.uuidString }
        if let message { info["message"] = message }
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
        self.agentVersion = info["version"] as? String ?? ""
        self.isRunning = info["running"] as? Bool ?? false
        self.isPaused = info["paused"] as? Bool ?? false
        self.currentID = (info["current"] as? String).flatMap { UUID(uuidString: $0) }
        self.failedIDs = (info["failed"] as? [String] ?? []).compactMap { UUID(uuidString: $0) }
        self.message = info["message"] as? String
        self.lockBusy = info["lockBusy"] as? Bool ?? false
        self.stateRevision = info["rev"] as? Int ?? 0
        self.quitting = info["quitting"] as? Bool ?? false
        self.lockID = (info["lockCur"] as? String).flatMap { UUID(uuidString: $0) }
        self.muted = info["muted"] as? Bool ?? true
        self.sceneHostRunning = info["host"] as? Bool ?? false
        if let item = (info["lrItem"] as? String).flatMap({ UUID(uuidString: $0) }),
           let state = (info["lrState"] as? String).flatMap({ LockRenderStatus.State(rawValue: $0) }) {
            self.lockRender = LockRenderStatus(itemID: item, state: state,
                                               progress: info["lrProg"] as? Double ?? 0,
                                               message: info["lrMsg"] as? String)
        } else {
            self.lockRender = nil
        }
    }
}

// MARK: - Endpoints

/// Agent side: listens for commands, posts statuses. Handlers run on the main actor.
public final class AgentEndpoint: NSObject {
    public var onCommand: (@MainActor (AgentCommand) -> Void)?
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
            self, selector: #selector(received(_:)), name: IPC.commandName,
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    public func post(_ status: AgentStatus) {
        DistributedNotificationCenter.default().postNotificationName(
            IPC.statusName, object: nil, userInfo: status.userInfo, deliverImmediately: true)
    }

    @objc private func received(_ note: Notification) {
        guard let command = AgentCommand(userInfo: note.userInfo) else { return }
        let handler = onCommand
        Task { @MainActor in handler?(command) }
    }
}

/// Settings side: listens for statuses, posts commands. Handlers run on the main actor.
public final class SettingsEndpoint: NSObject {
    public var onStatus: (@MainActor (AgentStatus) -> Void)?
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
            self, selector: #selector(received(_:)), name: IPC.statusName,
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    public func send(_ command: AgentCommand) {
        DistributedNotificationCenter.default().postNotificationName(
            IPC.commandName, object: nil, userInfo: command.userInfo, deliverImmediately: true)
    }

    @objc private func received(_ note: Notification) {
        guard let status = AgentStatus(userInfo: note.userInfo) else { return }
        let handler = onStatus
        Task { @MainActor in handler?(status) }
    }
}
