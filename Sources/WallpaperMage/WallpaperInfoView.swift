import AVFoundation
import SwiftUI
import Core

// The Info box: what a wallpaper is, in the Workshop's detail pane (from Steam's record of the item) and at the top of
// a library wallpaper's inspector, Home's and the playlist editor's (from its files and the tags it was downloaded
// with).

/// What a wallpaper's files say about it, read off the main actor once per library item.
struct WallpaperFacts: Sendable {
    /// The picture size: a scene's design size, a video's frame size; nil when unknown.
    let resolution: CGSize?
    /// A video's length; nil for a scene or when unknown.
    let duration: TimeInterval?
    /// What the wallpaper takes on disk; nil when its files cannot be read.
    let bytes: Int64?

    /// Keyed by VideoItem.id: a Workshop item downloaded again with new content becomes a new library item.
    @MainActor private(set) static var cache: [UUID: WallpaperFacts] = [:]

    @MainActor static func load(for item: VideoItem) async -> WallpaperFacts {
        if let cached = cache[item.id] { return cached }
        let facts = await Task.detached(priority: .userInitiated) { await read(item) }.value
        cache[item.id] = facts
        return facts
    }

    private static func read(_ item: VideoItem) async -> WallpaperFacts {
        let bytes = diskSize(of: item)
        if let scene = item.scene {
            return WallpaperFacts(resolution: CGSize(width: scene.designWidth, height: scene.designHeight),
                                  duration: nil, bytes: bytes)
        }
        async let resolution = WallpaperSheet.videoSize(item.url)
        let seconds = (try? await AVURLAsset(url: item.url).load(.duration))?.seconds
        return WallpaperFacts(resolution: await resolution,
                              duration: seconds.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }, bytes: bytes)
    }

    /// An imported wallpaper's whole folder in the library (its files, preview and project.json); a video of the
    /// user's own, which stays where it is, its file.
    private static func diskSize(of item: VideoItem) -> Int64? {
        let file = item.url.standardizedFileURL
        guard AppPaths.isInsideLibrary(file) else { return size(of: file) }
        let library = AppPaths.libraryDirectory.standardizedFileURL
        guard let folder = file.path.dropFirst(library.path.count + 1).split(separator: "/").first else { return nil }
        return size(of: library.appendingPathComponent(String(folder)))
    }

    /// A file's size, or the sum of the files in a folder.
    private static func size(of url: URL) -> Int64? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        guard values.isDirectory == true else { return values.fileSize.map(Int64.init) }
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else {
            return nil
        }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}

/// One line of the Info box.
struct InfoRow {
    let title: LocalizedStringKey
    /// nil while it is being read: the row shows a placeholder.
    let value: String?
}

/// The Info box under an "Info" title: rows of label and value and the topic tags as chips.
struct WallpaperInfoBox: View {
    let rows: [InfoRow]
    let tags: [String]

    var body: some View {
        InspectorSection(title: "Info") {
            VStack(alignment: .leading, spacing: 10) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(rows.indices, id: \.self) { index in
                        GridRow {
                            Text(rows[index].title).foregroundStyle(.secondary)
                            Group {
                                if let value = rows[index].value {
                                    Text(verbatim: value).fixedSize(horizontal: false, vertical: true)
                                } else {
                                    SkeletonBlock(height: 10, width: 64, radius: 3)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.callout)
                if !tags.isEmpty {
                    WrappingRows {
                        ForEach(tags, id: \.self) { WMChip(text: $0) }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
                shape.fill(Color.primary.opacity(0.05))
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            }
        }
    }

    // MARK: Values

    static func resolution(_ size: CGSize) -> String { "\(Int(size.width)) × \(Int(size.height))" }

    /// A Workshop resolution tag ("3840 x 2160", "Other resolution") written like a measured resolution.
    static func resolution(tag: String) -> String { tag.replacingOccurrences(of: " x ", with: " × ") }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }

    static func date(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

    /// The Workshop's age rating tag in the app's language.
    static func rating(_ tag: String) -> String {
        switch tag {
        case "Everyone": return String(localized: "Everyone")
        case "Questionable": return String(localized: "Questionable")
        case "Mature": return String(localized: "Mature")
        default: return tag
        }
    }
}

/// A library wallpaper's Info box: its type, resolution, length, size, age rating, author, when it was made and added
/// (VideoItem.created, VideoItem.updated) and topic tags. Its Workshop page is linked in the InspectorHeader above it.
@MainActor
struct WallpaperInfoSection: View {
    let item: VideoItem
    @State private var loaded: (id: VideoItem.ID, facts: WallpaperFacts)?

    /// nil while the files are being read.
    private var facts: WallpaperFacts? {
        if let loaded, loaded.id == item.id { return loaded.facts }
        return WallpaperFacts.cache[item.id]
    }

    var body: some View {
        let tags = item.tags ?? []
        WallpaperInfoBox(rows: rows(tags),
                         tags: WorkshopTags.topics(in: tags, kind: item.kind.rawValue))
            .task(id: item.id) {
                let id = item.id
                let facts = await WallpaperFacts.load(for: item)
                loaded = (id, facts)
            }
    }

    private func rows(_ tags: [String]) -> [InfoRow] {
        let facts = self.facts
        var rows = [InfoRow(title: "Type", value: item.isScene ? String(localized: "Scene") : String(localized: "Video"))]
        // What the files say: a placeholder while they are read, no row when they don't tell.
        func fact<Value>(_ title: LocalizedStringKey, _ path: KeyPath<WallpaperFacts, Value?>,
                         _ text: (Value) -> String) {
            if let facts {
                if let value = facts[keyPath: path] { rows.append(InfoRow(title: title, value: text(value))) }
            } else {
                rows.append(InfoRow(title: title, value: nil))
            }
        }
        fact("Resolution", \.resolution, WallpaperInfoBox.resolution)
        if !item.isScene {
            fact("Duration", \.duration) { seconds in
                Duration.seconds(seconds).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
            }
        }
        fact("Size", \.bytes, WallpaperInfoBox.bytes)
        if let rating = WorkshopTags.rating(in: tags) {
            rows.append(InfoRow(title: "Rating", value: WallpaperInfoBox.rating(rating)))
        }
        if let author = item.author { rows.append(InfoRow(title: "Author", value: author)) }
        if let created = item.created { rows.append(InfoRow(title: "Created", value: WallpaperInfoBox.date(created))) }
        if let added = item.updated { rows.append(InfoRow(title: "Added", value: WallpaperInfoBox.date(added))) }
        return rows
    }
}
