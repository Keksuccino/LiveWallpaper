import Foundation

// Playlists: named, ordered sets of library wallpapers that a display plays one after another. A playlist keeps its
// own options for each of its wallpapers (the display's options for a wallpaper apply only when the display shows it on
// its own), how long each wallpaper stays and how the next one comes in. Edited in the Settings app, played by the
// service's DisplayPlayer.

/// How a playlist's next wallpaper replaces the one on screen. Every kind waits until the next wallpaper is ready, so
/// the display never shows black while a scene loads.
public enum PlaylistTransition: String, Codable, CaseIterable, Sendable {
    /// The next wallpaper replaces the current one at once.
    case cut
    /// The next wallpaper fades in over the current one.
    case fade
    /// The current wallpaper fades to black, then the next one fades in from black.
    case fadeThroughBlack
    /// The current wallpaper blurs away while the next one comes into focus.
    case blur
    /// The next wallpaper fades in while it settles from slightly enlarged.
    case zoom
    /// The next wallpaper pushes the current one off to the left.
    case slide
}

/// What a display shows: one wallpaper, or a playlist it plays in turn.
public enum DisplayContent: Hashable, Sendable {
    case wallpaper(UUID)
    case playlist(UUID)

    public var wallpaperID: UUID? {
        if case .wallpaper(let id) = self { return id }
        return nil
    }

    public var playlistID: UUID? {
        if case .playlist(let id) = self { return id }
        return nil
    }
}

public struct Playlist: Identifiable, Codable, Equatable, Sendable {
    /// The shortest time a wallpaper stays: anything shorter would spend most of it loading.
    public static let minimumInterval: TimeInterval = 5
    public static let transitionDurations: ClosedRange<Double> = 0.25...5
    public static let defaultTransitionDuration: Double = 1

    public let id: UUID
    public var name: String
    /// The wallpapers in the order they play (VideoItem ids). A wallpaper is in a playlist at most once.
    public var items: [UUID]
    /// Per wallpaper of the playlist, keyed by VideoItem.id.uuidString: how it looks and sounds while the playlist
    /// shows it, on every display.
    public var wallpaperOptions: [String: WallpaperOptions]
    /// How long each wallpaper stays.
    public var intervalValue: Int
    public var intervalUnit: IntervalUnit
    public var transition: PlaylistTransition
    /// Seconds the transition takes (`transitionDurations`); a cut takes none.
    public var transitionDuration: Double
    /// The playlist's own picture: a file name in AppPaths.playlistImagesDirectory. nil = its wallpapers' previews.
    public var image: String?

    public init(id: UUID = UUID(), name: String, items: [UUID] = [], wallpaperOptions: [String: WallpaperOptions] = [:],
                intervalValue: Int = 5, intervalUnit: IntervalUnit = .minutes, transition: PlaylistTransition = .fade,
                transitionDuration: Double = Playlist.defaultTransitionDuration, image: String? = nil) {
        self.id = id
        self.name = name
        self.items = items
        self.wallpaperOptions = wallpaperOptions
        self.intervalValue = Playlist.clampedInterval(intervalValue)
        self.intervalUnit = intervalUnit
        self.transition = transition
        self.transitionDuration = Playlist.clampedTransitionDuration(transitionDuration)
        self.image = image
    }

    public static func clampedInterval(_ value: Int) -> Int { min(max(value, 1), 999) }

    public static func clampedTransitionDuration(_ seconds: Double) -> Double {
        min(max(seconds, transitionDurations.lowerBound), transitionDurations.upperBound)
    }

    public var intervalSeconds: TimeInterval {
        max(Playlist.minimumInterval, Double(intervalValue) * intervalUnit.multiplier)
    }

    public var intervalIsClamped: Bool {
        Double(intervalValue) * intervalUnit.multiplier < Playlist.minimumInterval
    }

    /// Seconds the transition between two wallpapers takes.
    public var transitionSeconds: Double { transition == .cut ? 0 : transitionDuration }

    public func options(for id: UUID) -> WallpaperOptions { wallpaperOptions[id.uuidString] ?? .standard }

    public var imageURL: URL? { image.map { AppPaths.playlistImagesDirectory.appendingPathComponent($0) } }

    // Every key but the id and the name may be missing, so a playlist written before a setting existed still loads.
    private enum CodingKeys: String, CodingKey {
        case id, name, items, wallpaperOptions, intervalValue, intervalUnit, transition, transitionDuration, image
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(UUID.self, forKey: .id),
                  name: try c.decode(String.self, forKey: .name),
                  items: try c.decodeIfPresent([UUID].self, forKey: .items) ?? [],
                  wallpaperOptions: try c.decodeIfPresent([String: WallpaperOptions].self,
                                                          forKey: .wallpaperOptions) ?? [:],
                  intervalValue: try c.decodeIfPresent(Int.self, forKey: .intervalValue) ?? 5,
                  intervalUnit: try c.decodeIfPresent(IntervalUnit.self, forKey: .intervalUnit) ?? .minutes,
                  transition: try c.decodeIfPresent(PlaylistTransition.self, forKey: .transition) ?? .fade,
                  transitionDuration: try c.decodeIfPresent(Double.self, forKey: .transitionDuration)
                      ?? Playlist.defaultTransitionDuration,
                  image: try c.decodeIfPresent(String.self, forKey: .image))
    }
}
