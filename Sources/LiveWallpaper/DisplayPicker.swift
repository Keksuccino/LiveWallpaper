import SwiftUI
import AppKit
import Core

// The top of Home: the connected displays, placed and sized as in System Settings > Displays, each showing its
// wallpaper. Clicking one makes it the display the library and the inspector work on.

@MainActor
struct DisplayPicker: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisplayArrangement(model: model)
            if let screen = model.selectedScreen { caption(screen) }
        }
        .lwGlassCard()
    }

    private func caption(_ screen: ScreenInfo) -> some View {
        let item = model.shownItem(on: screen.id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(screen.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(item?.name ?? "No live wallpaper. Click one in your library to use it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button(role: .destructive) {
                model.removeWallpaper(from: screen.id)
            } label: {
                Label("Remove Wallpaper", systemImage: "xmark.circle")
            }
            .disabled(model.wallpaper(on: screen.id) == nil)
            .help("Stop the live wallpaper on this display and go back to the macOS default wallpaper.")
        }
        .animation(LWMotion.content, value: item?.id)
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
        .animation(LWMotion.select, value: model.selectedDisplayID)
        .animation(LWMotion.content, value: model.screens)
    }
}

@MainActor
private struct DisplayTile: View {
    @ObservedObject var model: SettingsModel
    let screen: ScreenInfo
    let selected: Bool
    @State private var hovering = false

    private static let radius: CGFloat = 9

    var body: some View {
        let item = model.shownItem(on: screen.id)
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        Button { model.selectedDisplayID = screen.id } label: { face(item, shape: shape) }
            .buttonStyle(.plain)
            .overlay {
                shape.strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.28 : 0.14),
                                   lineWidth: selected ? 3 : 1)
            }
            .onHover { inside in withAnimation(LWMotion.hover) { hovering = inside } }
            .contextMenu {
                Button("Remove Wallpaper") { model.removeWallpaper(from: screen.id) }
                    .disabled(model.wallpaper(on: screen.id) == nil)
            }
            .animation(LWMotion.content, value: item?.id)
            .help(screen.name)
            .accessibilityLabel("\(screen.name), \(item?.name ?? "no live wallpaper")")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The display's wallpaper with its name. Color.clear takes exactly the tile's frame and the thumbnail fills it
    /// from an overlay, so a picture of another aspect ratio never grows the tile.
    private func face(_ item: VideoItem?, shape: RoundedRectangle) -> some View {
        Color.clear
            .overlay {
                if let item {
                    ItemThumbnail(item: item, broken: !FileManager.default.fileExists(atPath: item.path),
                                  showsHoverPreview: false, cornerRadius: Self.radius)
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
