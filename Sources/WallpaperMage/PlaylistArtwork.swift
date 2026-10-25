import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import Core

// A playlist's picture in the library, the inspector and the editor: the picture the user chose, or its first
// wallpapers' previews put together. One wallpaper fills it; two lie one above the other; three: two side by side
// above one across; four or more: the first four in a grid. Like ItemThumbnail it takes exactly the size it is
// offered.

@MainActor
struct PlaylistArtwork: View {
    let playlist: Playlist
    /// The playlist's wallpapers in order (only the first four are drawn).
    let items: [VideoItem]
    var cornerRadius: CGFloat = 12
    @State private var image: NSImage?

    private static let gap: CGFloat = 2

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.05))
            .overlay {
                if playlist.image != nil {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    }
                } else {
                    collage
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: playlist.image) {
            guard let url = playlist.imageURL else {
                image = nil
                return
            }
            let loaded = await ThumbnailCache.shared.image(at: url)
            withAnimation(.easeInOut(duration: 0.2)) { image = loaded }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var collage: some View {
        let gap = Self.gap
        switch items.count {
        case 0:
            Image(systemName: "rectangle.stack")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
        case 1:
            tile(items[0])
        case 2:
            VStack(spacing: gap) {
                tile(items[0])
                tile(items[1])
            }
        case 3:
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    tile(items[0])
                    tile(items[1])
                }
                tile(items[2])
            }
        default:
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    tile(items[0])
                    tile(items[1])
                }
                HStack(spacing: gap) {
                    tile(items[2])
                    tile(items[3])
                }
            }
        }
    }

    /// A preview filling its share of the picture.
    private func tile(_ item: VideoItem) -> some View {
        ItemThumbnail(item: item, cornerRadius: 0)
    }
}

/// The pictures users choose for their playlists, kept in AppPaths.playlistImagesDirectory. Each is a scaled-down copy
/// under a new name, so the original may move or go, and a cached picture is never one that was replaced.
enum PlaylistImage {
    /// Longest side of a kept picture in pixels: enough for the largest library card on a Retina display.
    static let maxPixelSize = 1200

    /// Reads the picture at `url`, scales it down and writes it; returns the new file's name (Playlist.image), nil when
    /// `url` is not a picture or the copy could not be written. Off the main actor: decoding can take a moment.
    static func store(_ url: URL) -> String? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // JPEG is far smaller for photos; a picture with transparency keeps it as PNG.
        let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
        let type: UTType = opaque.contains(image.alphaInfo) ? .jpeg : .png
        let name = UUID().uuidString + "." + (type.preferredFilenameExtension ?? "png")
        let target = AppPaths.playlistImagesDirectory.appendingPathComponent(name)
        guard (try? AppPaths.ensureDirectory(AppPaths.playlistImagesDirectory)) != nil,
              let destination = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image,
                                   [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? name : nil
    }
}

/// The open panel for a playlist's picture.
@MainActor
enum PlaylistImagePicker {
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose a picture for this playlist.")
        panel.prompt = String(localized: "Choose")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
