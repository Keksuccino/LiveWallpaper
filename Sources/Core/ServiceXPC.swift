import Foundation

// Messages between the UI (WallpaperMage.app) and the background service (WallpaperMageService), carried as JSON
// over the Unix socket in ServiceSocket.swift. The service is the only writer of state.json and does all rendering;
// the UI sends commands and shows status.

/// What the UI asks the service to do. One command per call; the reply carries the resulting status.
public enum ServiceCommand: Codable, Equatable, Sendable {
    /// The UI's edited library and settings. The service keeps the app's `muted` from its own copy, writes
    /// state.json (bumping the revision) and shows what the displays should show.
    case commit(LibraryState)
    case pause
    case resume
    case setMuted(Bool)                          // the whole app's mute (LibraryState.muted)
    case setStartsAtLogin(Bool)                  // the service's own login item (ServiceStatus.startsAtLogin)
    case quit                                    // stop and terminate the service
    case status                                  // reply with the current status (the login item read again)
    /// Previews of library wallpapers (LibraryPreview). The ones made again on request go first; the others replace
    /// those asked for before that are still waiting, in the order given.
    case makePreviews([PreviewRequest])
}

/// A library wallpaper's preview the service should make.
public struct PreviewRequest: Codable, Equatable, Sendable {
    public var item: VideoItem
    /// The options it is drawn with: those it has on the display the library works on.
    public var options: WallpaperOptions
    /// Made again even when it exists (the library's Refresh Preview).
    public var refresh: Bool

    public init(item: VideoItem, options: WallpaperOptions, refresh: Bool) {
        self.item = item
        self.options = options
        self.refresh = refresh
    }
}

/// Where the service's work on the library's previews stands.
public struct PreviewStatus: Codable, Equatable, Sendable {
    /// Goes up whenever a preview file was written or deleted.
    public var revision: Int
    /// The wallpapers whose previews are being made again on request, waiting or in the making.
    public var refreshing: [UUID]

    public init(revision: Int = 0, refreshing: [UUID] = []) {
        self.revision = revision
        self.refreshing = refreshing
    }
}

/// What one connected display shows.
public struct DisplayStatus: Codable, Equatable, Sendable {
    public var id: String                 // DisplayIdentity UUID
    public var itemID: UUID?              // what it shows live, nil when nothing
    public var error: String?             // user-facing reason its wallpaper could not be shown
    /// The picture file of the display's system wallpaper.
    public var systemWallpaper: String?
    /// The library item `systemWallpaper` is a still of; nil when it is some other picture.
    public var stillItemID: UUID?

    public init(id: String, itemID: UUID? = nil, error: String? = nil, systemWallpaper: String? = nil,
                stillItemID: UUID? = nil) {
        self.id = id
        self.itemID = itemID
        self.error = error
        self.systemWallpaper = systemWallpaper
        self.stillItemID = stillItemID
    }
}

/// What the service reports back after every command and whenever a display changes.
public struct ServiceStatus: Codable, Equatable, Sendable {
    public var paused: Bool
    /// Every wallpaper is silent (LibraryState.muted).
    public var muted: Bool
    public var displays: [DisplayStatus]  // every connected display
    public var stateRevision: Int         // revision of state.json the service last wrote or loaded
    public var message: String?           // latest user-facing message about the service as a whole
    /// The library's previews; nil from a service that makes none.
    public var previews: PreviewStatus?
    /// The service opens when the user logs in (Start on Launch); nil from a service that cannot say.
    public var startsAtLogin: Bool?

    public init(paused: Bool = false, muted: Bool = false, displays: [DisplayStatus] = [], stateRevision: Int = 0,
                message: String? = nil, previews: PreviewStatus? = nil, startsAtLogin: Bool? = nil) {
        self.paused = paused
        self.muted = muted
        self.displays = displays
        self.stateRevision = stateRevision
        self.message = message
        self.previews = previews
        self.startsAtLogin = startsAtLogin
    }

    public func display(_ id: String) -> DisplayStatus? { displays.first { $0.id == id } }
}

public enum ServiceCoding {
    public static func encode<T: Encodable>(_ value: T) -> Data { (try? JSONEncoder().encode(value)) ?? Data() }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? { try? JSONDecoder().decode(type, from: data) }
}
