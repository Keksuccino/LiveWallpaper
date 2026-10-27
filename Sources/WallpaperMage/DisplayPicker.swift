import SwiftUI
import AppKit
import Core

// The top of Home: the connected displays, placed and sized as in System Settings > Displays, each showing its
// wallpaper as it looks on the display. Clicking one makes it the display the library and the inspector work on.

@MainActor
struct DisplayPicker: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayArrangement(model: model)
            if let screen = model.selectedScreen { caption(screen) }
        }
        .wmGlassCard()
    }

    private func caption(_ screen: ScreenInfo) -> some View {
        let item = model.shownItem(on: screen.id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(description(item, on: screen))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                model.removeContent(from: screen.id)
            } label: {
                Label("Remove Wallpaper", systemImage: "xmark.circle")
            }
            .disabled(model.content(on: screen.id) == nil)
            .help("Stop the live wallpaper on this display and go back to the macOS default wallpaper.")
        }
        .animation(WMMotion.content, value: item?.id)
    }

    /// The wallpaper the display shows; with a playlist, the playlist's name first.
    private func description(_ item: VideoItem?, on screen: ScreenInfo) -> String {
        if let playlist = model.playlist(on: screen.id) {
            return item.map { "\(playlist.name) · \($0.name)" } ?? playlist.name
        }
        return item?.name ?? String(localized: "No live wallpaper. Click one in your library to use it here.")
    }
}

/// The displays as rounded rectangles in their arrangement, scaled to fit.
@MainActor
private struct DisplayArrangement: View {
    @ObservedObject var model: SettingsModel
    private let maxHeight: CGFloat = 190
    private let gap: CGFloat = 6

    var body: some View {
        let bounds = model.screens.reduce(CGRect.null) { $0.union($1.frame) }
        GeometryReader { geometry in
            let scale = min(geometry.size.width / bounds.width, geometry.size.height / bounds.height)
            let originX = (geometry.size.width - bounds.width * scale) / 2
            let originY = (geometry.size.height - bounds.height * scale) / 2
            ZStack(alignment: .topLeading) {
                ForEach(model.screens) { screen in
                    // Screen frames have their origin at the bottom left; the view's is at the top left.
                    let rect = CGRect(x: originX + (screen.frame.minX - bounds.minX) * scale,
                                      y: originY + (bounds.maxY - screen.frame.maxY) * scale,
                                      width: screen.frame.width * scale,
                                      height: screen.frame.height * scale)
                        .insetBy(dx: gap / 2, dy: gap / 2)
                    DisplayTile(model: model, screen: screen, selected: screen.id == model.selectedDisplayID)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .aspectRatio(bounds.isEmpty ? 16 / 9 : bounds.width / bounds.height, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: maxHeight)
        .animation(WMMotion.select, value: model.selectedDisplayID)
        .animation(WMMotion.content, value: model.screens)
    }
}

/// A display in the arrangement. It shows the display's system wallpaper, which the service keeps a still of its
/// live wallpaper framed exactly as on the display, so the tile looks like the display itself. Until the still of a
/// newly chosen wallpaper exists, the wallpaper's preview stands in for it, framed the same way. A new still of what
/// the tile shows (a wallpaper's settled still after its quick one, a changed setting) fades in over the old one.
@MainActor
private struct DisplayTile: View {
    @ObservedObject var model: SettingsModel
    let screen: ScreenInfo
    let selected: Bool
    @State private var hovering = false
    @State private var still: LoadedStill?
    /// The still `still` replaced on the tile, kept beneath the new one while it fades in, so the fade never lets
    /// the background through.
    @State private var replaced: NSImage?

    private static let radius: CGFloat = 9
    /// The display-sized still is scaled down to this for the tile.
    private static let stillPixelSize = 960

    private struct LoadedStill {
        let url: URL
        let stillOf: UUID?
        let image: NSImage
    }

    var body: some View {
        let item = model.shownItem(on: screen.id)
        let wallpaper = model.systemWallpaper(on: screen.id)
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        Button { model.selectedDisplayID = screen.id } label: {
            face(item, still: showsStill(of: item, wallpaper: wallpaper) ? still : nil, shape: shape)
        }
        .buttonStyle(.plain)
        .overlay {
            shape.strokeBorder(selected ? WMTheme.accent : Color.primary.opacity(hovering ? 0.28 : 0.14),
                               lineWidth: selected ? 3 : 1)
        }
        .onHover { inside in withAnimation(WMMotion.hover) { hovering = inside } }
        .contextMenu {
            Button("Remove Wallpaper") { model.removeContent(from: screen.id) }
                .disabled(model.content(on: screen.id) == nil)
        }
        .task(id: wallpaper?.url) {
            guard let wallpaper,
                  let image = await ThumbnailCache.shared.image(at: wallpaper.url, maxPixelSize: Self.stillPixelSize)
            else { return }
            replaced = showsStill(of: model.shownItem(on: screen.id), wallpaper: wallpaper) ? still?.image : nil
            withAnimation(WMMotion.content) {
                still = LoadedStill(url: wallpaper.url, stillOf: wallpaper.stillOf, image: image)
            } completion: {
                replaced = nil
            }
        }
        .help(screen.name)
        .accessibilityLabel("\(screen.name), \(item?.name ?? String(localized: "no live wallpaper"))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Whether the loaded still shows what the display shows: the system wallpaper as such when nothing is live,
    /// else a still of the live item, which may be an older still of it while the next one loads (a setting changed).
    private func showsStill(of item: VideoItem?, wallpaper: (url: URL, stillOf: UUID?)?) -> Bool {
        guard let still, let item else { return true }
        return wallpaper?.stillOf == item.id && (still.url == wallpaper?.url || still.stillOf == item.id)
    }

    /// Color.clear takes exactly the tile's frame and the picture fills it from an overlay, so a picture of
    /// another aspect ratio never grows the tile.
    private func face(_ item: VideoItem?, still: LoadedStill?, shape: RoundedRectangle) -> some View {
        Color.clear
            .overlay {
                if let still {
                    ZStack {
                        if let replaced { Image(nsImage: replaced).resizable().scaledToFill() }
                        Image(nsImage: still.image)
                            .resizable()
                            .scaledToFill()
                            .id(still.url)
                            .transition(.opacity)
                    }
                    .transition(.opacity)
                } else if let item {
                    WallpaperPreview(item: item, options: model.shownOptions(on: screen.id, for: item.id))
                        .id(item.id)
                        .transition(.opacity)
                } else {
                    shape.fill(Color.primary.opacity(0.06))
                        .overlay {
                            Image(systemName: "display")
                                .font(.system(size: 18, weight: .light))
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(screen.name)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
            }
            .clipShape(shape)
            .contentShape(shape)
    }
}

/// A wallpaper's preview picture placed on a display roughly the way the wallpaper is: its alignment, blurred bars
/// and flip (position and zoom aside).
@MainActor
private struct WallpaperPreview: View {
    let item: VideoItem
    let options: WallpaperOptions
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image { placed(Image(nsImage: image).resizable()) }
        }
        .clipped()
        .task(id: item.id) {
            let loaded = await ThumbnailCache.shared.image(for: item)
            withAnimation(WMMotion.content) { image = loaded }
        }
    }

    private func placed(_ picture: Image) -> some View {
        Group {
            switch options.alignment {
            case .cover:
                picture.scaledToFill()
            case .stretch:
                picture
            case .fill, .center, .free:
                if options.blurBars {
                    picture.scaledToFill()
                        .blur(radius: 12)
                        .overlay { picture.scaledToFit() }
                } else {
                    picture.scaledToFit()
                }
            }
        }
        .scaleEffect(x: options.flip ? -1 : 1, y: 1)
    }
}
