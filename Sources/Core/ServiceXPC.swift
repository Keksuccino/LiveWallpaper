import Foundation

// Messages between the UI (LiveWallpaper.app) and the background service (LiveWallpaperService), carried as JSON
// over the Unix socket in ServiceSocket.swift. The service is the only writer of state.json and does all rendering;
// the UI sends commands and shows status.

/// What the UI asks the service to do. One command per call; the reply carries the resulting status.
public enum ServiceCommand: Codable, Equatable, Sendable {
    /// The UI's edited library and settings. The service keeps each display's `muted` from its own copy, writes
    /// state.json (bumping the revision) and shows what the displays should show.
    case commit(LibraryState)
    case pause
    case resume
    case next                                    // every rotating display moves on to its next wallpaper
    case setMuted(display: String?, muted: Bool) // nil = every display
    case quit                                    // stop and terminate the service
    case status                                  // no-op: just reply with the current status
}

/// What one connected display shows.
public struct DisplayStatus: Codable, Equatable, Sendable {
    public var id: String                 // DisplayIdentity UUID
    public var itemID: UUID?              // what it shows live, nil when nothing
    public var error: String?             // user-facing reason its wallpaper could not be shown
    public var muted: Bool
    /// The picture file of the display's system wallpaper.
    public var systemWallpaper: String?
    /// The library item `systemWallpaper` is a still of; nil when it is some other picture.
    public var stillItemID: UUID?

    public init(id: String, itemID: UUID? = nil, error: String? = nil, muted: Bool = true,
                systemWallpaper: String? = nil, stillItemID: UUID? = nil) {
        self.id = id
        self.itemID = itemID
        self.error = error
        self.muted = muted
        self.systemWallpaper = systemWallpaper
        self.stillItemID = stillItemID
    }
}

/// What the service reports back after every command and whenever a display changes.
public struct ServiceStatus: Codable, Equatable, Sendable {
    public var paused: Bool
    public var displays: [DisplayStatus]  // every connected display
    public var stateRevision: Int         // revision of state.json the service last wrote or loaded
    public var message: String?           // latest user-facing message about the service as a whole

    public init(paused: Bool = false, displays: [DisplayStatus] = [], stateRevision: Int = 0, message: String? = nil) {
        self.paused = paused
        self.displays = displays
        self.stateRevision = stateRevision
        self.message = message
    }

    public func display(_ id: String) -> DisplayStatus? { displays.first { $0.id == id } }

    /// Some display shows a live wallpaper.
    public var isLive: Bool { displays.contains { $0.itemID != nil } }
}

public enum ServiceCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }
}
