import Foundation

// Messages between the UI (LiveWallpaper.app) and the background service (LiveWallpaperService), carried as JSON
// over the Unix socket in ServiceSocket.swift. The service is the only writer of state.json and does all rendering;
// the UI sends commands and shows status.

/// What the UI asks the service to do. One command per call; the reply carries the resulting status.
public enum ServiceCommand: Codable, Equatable, Sendable {
    /// The UI's edited library and settings. The service merges `muted` from its own copy, writes state.json
    /// (bumping the revision) and reconciles playback. Replaces today's "Settings writes state.json + .reload".
    case commit(LibraryState)
    case start(itemID: UUID?)   // begin playback (item, else the selection)
    case stop                   // stop playback
    case pause
    case resume
    case next
    case setMuted(Bool)
    case quit                   // stop and terminate the service
    case status                 // no-op: just reply with the current status
}

/// What the service reports back after every command and whenever playback changes.
public struct ServiceStatus: Codable, Equatable, Sendable {
    public enum Playback: String, Codable, Sendable { case stopped, playing, paused }

    public var playback: Playback
    public var itemID: UUID?              // what is on the desktop, nil when nothing is
    public var error: String?             // user-facing reason the last item could not play
    public var stateRevision: Int         // revision of state.json the service last wrote or loaded
    public var muted: Bool
    public var message: String?           // latest user-facing message (e.g. "Couldn't play …")

    public init(playback: Playback = .stopped, itemID: UUID? = nil, error: String? = nil, stateRevision: Int = 0,
                muted: Bool = true, message: String? = nil) {
        self.playback = playback
        self.itemID = itemID
        self.error = error
        self.stateRevision = stateRevision
        self.muted = muted
        self.message = message
    }
}

public enum ServiceCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }
}
