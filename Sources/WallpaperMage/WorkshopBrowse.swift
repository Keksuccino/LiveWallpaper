import Foundation
import CoreGraphics

// What the Workshop browser asks Steam for: the sorts and filters of Wallpaper Engine's own Workshop browser, which
// WorkshopModel keeps (and remembers in UserDefaults) and `WorkshopKit.API.queryURL` turns into a QueryFiles request.
// The tags are Steam's own, in English, exactly as the Workshop's items carry them; the filters show them in the words
// of Wallpaper Engine's browser.

/// The Workshop browser's sorts, as Wallpaper Engine's browser offers them: Steam's rankings of the whole Workshop.
/// Every sort also orders a search and a filtered list.
enum WorkshopSort: String, CaseIterable, Identifiable {
    case topRated, popularYear, popularMonth, popularWeek, popularToday, mostRecent, mostUpVotes, mostSubscriptions

    /// A new browser's sort.
    static let standard = WorkshopSort.topRated
    /// The sort a new search switches to, as Wallpaper Engine does: with a search text, Steam ranks Top Rated by how
    /// well the items match it.
    static let search = WorkshopSort.topRated

    var id: String { rawValue }

    var label: String {
        switch self {
        case .topRated: return String(localized: "Top Rated")
        case .popularYear: return String(localized: "Most Popular (Year)")
        case .popularMonth: return String(localized: "Most Popular (Month)")
        case .popularWeek: return String(localized: "Most Popular (Week)")
        case .popularToday: return String(localized: "Most Popular (Today)")
        case .mostRecent: return String(localized: "Most Recent")
        case .mostUpVotes: return String(localized: "Most Up Votes")
        case .mostSubscriptions: return String(localized: "Most Subscriptions")
        }
    }

    /// Steam's EPublishedFileQueryType.
    var queryType: Int {
        switch self {
        case .topRated: return 0                                                    // RankedByVote
        case .popularYear, .popularMonth, .popularWeek, .popularToday: return 3     // RankedByTrend
        case .mostRecent: return 1                                                  // RankedByPublicationDate
        case .mostUpVotes: return 11                                                // RankedByVotesUp
        case .mostSubscriptions: return 9                                           // RankedByTotalUniqueSubscriptions
        }
    }

    /// How many days of votes a trend ranks by; nil for the other sorts.
    var trendDays: Int? {
        switch self {
        case .popularYear: return 365
        case .popularMonth: return 30
        case .popularWeek: return 7
        case .popularToday: return 1
        default: return nil
        }
    }
}

/// A group of Workshop tags the browser filters by, in the order of Wallpaper Engine's browser. An item passes a group
/// when it carries one of the group's tags that are on.
enum WorkshopFilterGroup: String, CaseIterable, Identifiable, Codable, CodingKeyRepresentable {
    case type, category, rating, resolution, genre

    var id: String { rawValue }

    /// The group's tags, in sections with a heading; only the resolutions have more than one.
    var sections: [WorkshopTagSection] {
        switch self {
        case .type: return [WorkshopTagSection(tags: ["Scene", "Video", "Web"])]
        case .category: return [WorkshopTagSection(tags: ["Wallpaper", "Preset"])]
        case .rating: return [WorkshopTagSection(tags: WorkshopTags.ratings)]
        case .resolution: return WorkshopTagSection.resolutions
        case .genre:
            return [WorkshopTagSection(tags: [
                "Abstract", "Animal", "Anime", "Cartoon", "CGI", "Cyberpunk", "Fantasy", "Game", "Girls", "Guys",
                "Landscape", "Medieval", "Memes", "MMD", "Music", "Nature", "Pixel art", "Relaxing", "Retro", "Sci-Fi",
                "Sports", "Technology", "Television", "Vehicle", "Unspecified",
            ])]
        }
    }

    var tags: [String] { sections.flatMap(\.tags) }
}

/// Tags of a filter group under one heading (none for a group of a single section).
struct WorkshopTagSection: Identifiable {
    var title: String? = nil
    let tags: [String]

    var id: String { tags[0] }

    /// Steam's resolution tags, grouped like Wallpaper Engine's browser groups them.
    static var resolutions: [WorkshopTagSection] {
        [
            WorkshopTagSection(title: String(localized: "Widescreen"), tags: [
                "Standard Definition", "1280 x 720", "1366 x 768", "1920 x 1080", "2560 x 1440", "3840 x 2160",
            ]),
            WorkshopTagSection(title: String(localized: "Ultrawide"), tags: [
                "Ultrawide Standard Definition", "Ultrawide 2560 x 1080", "Ultrawide 3440 x 1440",
            ]),
            WorkshopTagSection(title: String(localized: "Dual Displays"), tags: [
                "Dual Standard Definition", "Dual 3840 x 1080", "Dual 5120 x 1440", "Dual 7680 x 2160",
            ]),
            WorkshopTagSection(title: String(localized: "Triple Displays"), tags: [
                "Triple Standard Definition", "Triple 4096 x 768", "Triple 5760 x 1080", "Triple 7680 x 1440",
                "Triple 11520 x 2160",
            ]),
            WorkshopTagSection(title: String(localized: "Portrait Displays"), tags: [
                "Portrait Standard Definition", "Portrait 720 x 1280", "Portrait 1080 x 1920", "Portrait 1440 x 2560",
                "Portrait 2160 x 3840",
            ]),
            WorkshopTagSection(title: String(localized: "Other"), tags: ["Other resolution", "Dynamic resolution"]),
        ]
    }
}

/// What the browser's filters let through, as in Wallpaper Engine's browser: per group, the tags that are off (a group
/// with none off lets every item through, one with all off none), and the Show Only tags every item has to carry.
struct WorkshopFilters: Codable, Hashable {
    var off: [WorkshopFilterGroup: Set<String>] = [:]
    var required: Set<String> = []

    /// A new browser's filters: everything except questionable and mature items.
    static let standard = WorkshopFilters(off: [.rating: ["Questionable", "Mature"]])

    /// The tags the Show Only filter can require, in its order.
    static let showOnlyTags = ["Approved", "Audio responsive", "Customizable"]

    func isOn(_ tag: String, in group: WorkshopFilterGroup) -> Bool { !(off[group]?.contains(tag) ?? false) }

    /// Switches `tags` of `group` on or off.
    mutating func set(_ tags: [String], in group: WorkshopFilterGroup, on: Bool) {
        var tagsOff = off[group] ?? []
        if on { tagsOff.subtract(tags) } else { tagsOff.formUnion(tags) }
        off[group] = tagsOff.isEmpty ? nil : tagsOff
    }

    mutating func setRequired(_ tag: String, _ isRequired: Bool) {
        if isRequired { required.insert(tag) } else { required.remove(tag) }
    }

    /// The tags of `group` an item may carry, in the group's order; nil when the group lets every item through.
    func allowed(in group: WorkshopFilterGroup) -> [String]? {
        let tags = group.tags
        let allowed = tags.filter { isOn($0, in: group) }
        return allowed.count == tags.count ? nil : allowed
    }

    /// The Show Only tags every item has to carry, in the filter's order.
    var requiredTags: [String] { Self.showOnlyTags.filter(required.contains) }

    /// Some group has all of its tags off, so no item can pass.
    var matchesNothing: Bool { WorkshopFilterGroup.allCases.contains { allowed(in: $0)?.isEmpty == true } }

    /// Persisted form: JSON text (UserDefaults, WorkshopKit.Prefs.filters).
    var json: String {
        (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    init(off: [WorkshopFilterGroup: Set<String>] = [:], required: Set<String> = []) {
        self.off = off
        self.required = required
    }

    init?(json: String) {
        guard !json.isEmpty, let filters = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = filters
    }
}

extension WorkshopTags {
    /// The words the filters show for a Workshop tag. Resolutions without their section's name, which their heading
    /// shows.
    static func label(_ tag: String) -> String {
        switch tag {
        case "Scene": return String(localized: "Scene")
        case "Video": return String(localized: "Video")
        case "Web": return String(localized: "Web")
        case "Wallpaper": return String(localized: "Wallpaper")
        case "Preset": return String(localized: "Preset")
        case "Everyone", "Questionable", "Mature": return WallpaperInfoBox.rating(tag)
        case "Other resolution": return String(localized: "Other resolution")
        case "Dynamic resolution": return String(localized: "Dynamic resolution")
        case "Abstract": return String(localized: "Abstract")
        case "Animal": return String(localized: "Animal")
        case "Anime": return String(localized: "Anime")
        case "Cartoon": return String(localized: "Cartoon")
        case "CGI": return String(localized: "CGI")
        case "Cyberpunk": return String(localized: "Cyberpunk")
        case "Fantasy": return String(localized: "Fantasy")
        case "Game": return String(localized: "Game")
        case "Girls": return String(localized: "Girls")
        case "Guys": return String(localized: "Guys")
        case "Landscape": return String(localized: "Landscape")
        case "Medieval": return String(localized: "Medieval")
        case "Memes": return String(localized: "Memes")
        case "MMD": return String(localized: "MMD (MikuMikuDance)")
        case "Music": return String(localized: "Music")
        case "Nature": return String(localized: "Nature")
        case "Pixel art": return String(localized: "Pixel art")
        case "Relaxing": return String(localized: "Relaxing")
        case "Retro": return String(localized: "Retro")
        case "Sci-Fi": return String(localized: "Sci-Fi")
        case "Sports": return String(localized: "Sports")
        case "Technology": return String(localized: "Technology")
        case "Television": return String(localized: "Television")
        case "Vehicle": return String(localized: "Vehicle")
        case "Unspecified": return String(localized: "Unspecified genre")
        case "Approved": return String(localized: "Approved")
        case "Audio responsive": return String(localized: "Audio responsive")
        case "Customizable": return String(localized: "Customizable")
        default: break
        }
        if tag.hasSuffix("Standard Definition") { return String(localized: "Standard definition") }
        guard let size = pixelSize(of: tag) else { return tag }
        let name = "\(Int(size.width)) × \(Int(size.height))"
        switch size {
        case CGSize(width: 1920, height: 1080): return "\(name) · Full HD"
        case CGSize(width: 3840, height: 2160): return "\(name) · 4K"
        default: return name
        }
    }

    /// A resolution tag's pixel size ("Dual 3840 x 1080" -> 3840 × 1080); nil for other tags.
    static func pixelSize(of tag: String) -> CGSize? {
        let numbers = tag.split(separator: " ").compactMap { Int($0) }
        guard numbers.count == 2, tag.contains(" x ") else { return nil }
        return CGSize(width: numbers[0], height: numbers[1])
    }

    /// The resolution tags of wallpapers that look sharp on displays of `sizes` (pixels): per display, the sizes of its
    /// shape (widescreen, ultrawide, dual, triple or portrait) at least as large as the display, or the largest of
    /// them for a display larger than all; and wallpapers that adapt to any resolution.
    static func resolutions(fitting sizes: [CGSize]) -> Set<String> {
        let sections = WorkshopTagSection.resolutions
        var fitting: Set<String> = ["Dynamic resolution"]
        for size in sizes where size.width > 0 && size.height > 0 {
            let ratio = size.width / size.height
            // Section order: widescreen, ultrawide, dual, triple, portrait. Widescreen takes 16:10 and 4:3 too.
            let shape = ratio < 1 ? 4 : ratio < 2.1 ? 0 : ratio < 2.9 ? 1 : ratio < 4.3 ? 2 : 3
            let candidates = sections[shape].tags.compactMap { tag in pixelSize(of: tag).map { (tag, $0) } }
            let large = candidates.filter { $0.1.width >= size.width && $0.1.height >= size.height }
            if large.isEmpty {
                if let largest = candidates.max(by: { $0.1.width < $1.1.width }) { fitting.insert(largest.0) }
            } else {
                fitting.formUnion(large.map(\.0))
            }
        }
        return fitting
    }
}

/// The birthdate check in front of NSFW wallpapers (Steam's "Mature" rating). An adult's birthdate is remembered
/// (WorkshopKit.Prefs.birthdate), so it is asked for only once; a minor's is not, so it is asked for again the next
/// time NSFW is switched on.
enum WorkshopAgeCheck {
    /// The age rating tag the check guards.
    static let tag = "Mature"
    static let adultAge = 18

    /// Gregorian in the current time zone, so a birthdate is the same calendar day whatever calendar the user reads.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// Whether someone born on `birthdate` is `adultAge` or older at `now`.
    static func isAdult(born birthdate: Date, at now: Date = Date()) -> Bool {
        let calendar = calendar
        guard let adult = calendar.date(byAdding: .year, value: adultAge, to: calendar.startOfDay(for: birthdate)) else {
            return false
        }
        return adult <= now
    }

    /// The remembered birthdate shows an adult, so NSFW can come on without asking.
    static var isConfirmedAdult: Bool {
        date(fromDay: WorkshopKit.Prefs.birthdate.value).map { isAdult(born: $0) } ?? false
    }

    /// Whether `birthdate` shows an adult; remembers it when it does.
    static func confirm(_ birthdate: Date) -> Bool {
        guard isAdult(born: birthdate) else { return false }
        WorkshopKit.Prefs.birthdate.value = day(of: birthdate)
        return true
    }

    /// The calendar day of `date` as stored ("2001-04-17").
    static func day(of date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The start of a stored calendar day; nil for anything else, a day that does not exist (31 February) included.
    static func date(fromDay day: String) -> Date? {
        let numbers = day.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return date(year: numbers[0], month: numbers[1], day: numbers[2])
    }

    /// The day typed as `day`, `month` and a four-digit `year`, when it is a real day from 1900 up to `now`; nil
    /// otherwise.
    static func birthdate(day: String, month: String, year: String, now: Date = Date()) -> Date? {
        guard year.count == 4, let year = Int(year), year >= 1900, let month = Int(month), let day = Int(day),
              let date = date(year: year, month: month, day: day), date <= now else { return nil }
        return date
    }

    /// The start of that day, nil when it does not exist: Calendar would roll 31 February over into March.
    private static func date(year: Int, month: Int, day: Int) -> Date? {
        let calendar = calendar
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return parts.year == year && parts.month == month && parts.day == day ? date : nil
    }
}

/// A display's own resolution in pixels, whatever scaled mode it runs in: its largest mode marked native, else its
/// largest mode without HiDPI scaling. The largest mode of all can be a HiDPI one larger than the panel (a 4K display
/// offers 6720 × 3780 pixels, downsampled) or one a 1080p display accepts and scales down.
func nativePixelSize(of display: CGDirectDisplayID) -> CGSize? {
    let nativeFlag: UInt32 = 0x0200_0000   // kDisplayModeNativeFlag (IOKit's IOGraphicsTypes.h)
    let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else { return nil }
    let native = modes.filter { $0.ioFlags & nativeFlag != 0 }
    let candidates = native.isEmpty ? modes.filter { $0.pixelWidth == $0.width } : native
    return candidates.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
        .map { CGSize(width: $0.pixelWidth, height: $0.pixelHeight) }
}
