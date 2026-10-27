import Foundation

// How Home orders its library: the sort menu and the order picker in the library's title row, remembered across
// launches in UserDefaults (HomeView).

/// What Home's library is sorted by.
enum LibrarySort: String, CaseIterable, Identifiable {
    /// When an entry came into the library or last changed (VideoItem.updated, Playlist.updated).
    case updated
    /// Playlists, then scenes, then videos (LibraryKind's order), or the other way round.
    case kind
    /// When an entry itself was made, a Workshop item last updated on the Workshop (LibraryEntry.created).
    case created

    var id: Self { self }

    var label: String {
        switch self {
        case .updated: return String(localized: "Latest")
        case .kind: return String(localized: "By Type")
        case .created: return String(localized: "Creation Date")
        }
    }
}

/// The library's sort and its direction. One direction serves every sort.
struct LibraryOrder: Equatable {
    var sort: LibrarySort = .updated
    /// false (the default): newest first, and playlists first by type; true: the other way round.
    var ascending = false

    /// `entries`, in the library's own order (LibraryEntry.library), as Home lists them. Sorted by when they were added
    /// or updated, the order turns around exactly; entries from before the library kept that date count as older than
    /// all others, in the library's own order. Entries of one type or one creation date list the most recently added
    /// or updated first, and entries without a creation date come last either way.
    func sorted(_ entries: [LibraryEntry]) -> [LibraryEntry] {
        struct Keyed {
            let entry: LibraryEntry
            let kind: LibraryKind
            let created: Date?
            /// Later = more recent. The position makes it unique, so every sort below is a total order.
            let recency: (Date, Int)
        }
        let keyed = entries.enumerated().map { position, entry in
            Keyed(entry: entry, kind: entry.kind, created: entry.created,
                  recency: (entry.updated ?? .distantPast, position))
        }
        let ascending = ascending
        let ordered: [Keyed]
        switch sort {
        case .updated:
            ordered = keyed.sorted { ascending ? $0.recency < $1.recency : $0.recency > $1.recency }
        case .kind:
            // Types have no direction of their own: descending, the default, lists them in LibraryKind's order
            // (playlists first).
            ordered = keyed.sorted { a, b in
                if a.kind != b.kind { return ascending ? a.kind > b.kind : a.kind < b.kind }
                return a.recency > b.recency
            }
        case .created:
            ordered = keyed.sorted { a, b in
                switch (a.created, b.created) {
                case let (x?, y?) where x != y: return ascending ? x < y : x > y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.recency > b.recency
                }
            }
        }
        return ordered.map(\.entry)
    }
}
