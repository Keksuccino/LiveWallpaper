import SwiftUI
import AppKit
import Core

// The shared visual language for the Settings app. Keep every custom colour, radius, curve and
// reusable surface here so the library, Workshop and Steam Setup feel like one product.

enum LWTheme {
    static let contentPadding: CGFloat = 24
    static let cardRadius: CGFloat = 16
    static let panelRadius: CGFloat = 20
    static let sidebarWidth: CGFloat = 224
    static let inspectorWidth: CGFloat = 320
    static let gridSpacing: CGFloat = 18
    static let cardMinWidth: CGFloat = 250
}

enum LWMotion {
    static let hover = Animation.easeOut(duration: 0.16)
    static let select = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let hero = Animation.spring(response: 0.42, dampingFraction: 0.88)
    static let panel = Animation.easeInOut(duration: 0.26)
    static let content = Animation.easeInOut(duration: 0.22)
    static let success = Animation.spring(response: 0.36, dampingFraction: 0.72)
}

/// A solid content surface. Cards use this instead of stacking translucent materials.
struct LWCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = LWTheme.cardRadius
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    }
            }
    }
}

/// Floating glass for the navigation/transport layer only (hero controls, status popover, pills).
/// On macOS 26 this is real Liquid Glass; earlier systems get a quiet material fallback.
struct GlassPanel<Content: View>: View {
    var radius: CGFloat = 18
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if #available(macOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(.regular, in: shape)
        } else {
            content
                .background(reduceTransparency
                            ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                            : AnyShapeStyle(.ultraThinMaterial),
                            in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
            }
            content
        }
    }
}

struct LWChip: View {
    let text: String
    var tint: Color? = nil
    var filled: Bool = false
    var icon: String? = nil

    private var color: Color { tint ?? .secondary }

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(filled ? Color.white : color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background {
            Capsule().fill(filled ? color : color.opacity(0.13))
        }
        .overlay {
            if !filled {
                Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5)
            }
        }
    }
}

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulsing {
                    Circle().stroke(color.opacity(0.45), lineWidth: 1)
                        .scaleEffect(on ? 2.1 : 0.9)
                        .opacity(on ? 0 : 1)
                }
            }
            .animation(pulsing ? .easeOut(duration: 1.2).repeatForever(autoreverses: false) : .default, value: on)
            .onAppear { on = pulsing }
            .onChange(of: pulsing) { on = $0 }
    }
}

/// Small animated equaliser shown while a wallpaper is on screen.
struct ActivityBars: View {
    let playing: Bool
    let paused: Bool
    var tint: Color = .accentColor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.09, paused: !playing || paused || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(tint)
                        .frame(width: 2.5, height: height(index: index, time: t))
                }
            }
            .frame(height: 13, alignment: .bottom)
        }
        .opacity(playing ? 1 : 0)
        .accessibilityHidden(true)
    }

    private func height(index: Int, time: TimeInterval) -> CGFloat {
        guard !reduceMotion else { return index == 1 ? 9 : 5 }
        let phase = time * (2.1 + Double(index) * 0.35) + Double(index) * 1.7
        return 4 + CGFloat((sin(phase) + 1) / 2) * 9
    }
}

struct ProgressRing: View {
    let progress: Double
    var size: CGFloat = 34
    var lineWidth: CGFloat = 3
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.25), value: progress)
            Text("\(Int((min(max(progress, 0), 1) * 100).rounded()))")
                .font(.system(size: 9, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }
}

extension View {
    func hoverLift(_ enabled: Bool = true) -> some View {
        modifier(HoverLiftModifier(enabled: enabled))
    }

    /// The inspector on macOS 14+, a trailing panel on older systems. Keeps the app on its macOS 13 floor.
    @ViewBuilder
    func lwInspector<Inspector: View>(isPresented: Binding<Bool>,
                                      @ViewBuilder inspector: @escaping () -> Inspector) -> some View {
        if #available(macOS 14.0, *) {
            self.inspector(isPresented: isPresented) {
                inspector()
                    .inspectorColumnWidth(min: 280, ideal: LWTheme.inspectorWidth, max: 380)
            }
        } else {
            HStack(spacing: 0) {
                self
                if isPresented.wrappedValue {
                    Divider()
                    inspector().frame(width: LWTheme.inspectorWidth)
                }
            }
        }
    }
}

private struct HoverLiftModifier: ViewModifier {
    let enabled: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(enabled && hovering && !reduceMotion ? 1.015 : 1)
            .shadow(color: .black.opacity(hovering && enabled ? 0.22 : 0), radius: hovering ? 16 : 0, y: hovering ? 8 : 0)
            .animation(LWMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// Shared thumbnail loading. Decodes once, keeps the result, and never does disk work in `body`.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for item: VideoItem) async -> NSImage? {
        let key = (item.previewPath ?? item.path) as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image: NSImage?
        if let preview = item.previewPath, let loaded = NSImage(contentsOfFile: preview) {
            image = loaded
        } else if !item.isScene,
                  let cgImage = await VideoStills.cgImage(for: item.url,
                                                          maxPixelSize: CGSize(width: 640, height: 360)) {
            image = NSImage(cgImage: cgImage, size: .zero)
        } else {
            image = nil
        }

        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}

struct ItemThumbnail: View {
    let item: VideoItem
    var broken = false
    var showsHoverPreview = true
    var cornerRadius: CGFloat = 10

    @State private var image: NSImage?
    @State private var hovering = false
    @State private var previewVisible = false
    @State private var previewTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .quaternaryLabelColor).opacity(0.18))

            if broken {
                VStack(spacing: 5) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 18))
                    Text("Missing").font(.caption2)
                }
                .foregroundStyle(.orange)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: item.isScene ? "photo" : "film")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
            }

            if previewVisible && !broken && !item.isScene {
                HoverPreview(item: item)
                    .transition(.opacity)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: [item.path, item.previewPath ?? ""]) {
            let loaded = await ThumbnailCache.shared.image(for: item)
            withAnimation(.easeInOut(duration: 0.2)) { image = loaded }
        }
        .onHover(perform: hoverChanged)
        .onDisappear {
            previewTask?.cancel()
            previewVisible = false
        }
    }

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        previewTask?.cancel()
        guard inside, showsHoverPreview, !item.isScene, !reduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled else {
            withAnimation(.easeOut(duration: 0.16)) { previewVisible = false }
            return
        }
        previewTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard !Task.isCancelled, hovering else { return }
            withAnimation(.easeInOut(duration: 0.2)) { previewVisible = true }
        }
    }
}

private struct HoverPreview: View {
    let item: VideoItem
    @StateObject private var player = PreviewPlayer()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Color.black
            } else {
                PlayerSurface(player: player.player)
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            player.load(item.url)
            player.setActive(true)
        }
        .onDisappear { player.setActive(false) }
    }
}

/// A drop-in empty state used by the library and Workshop.
struct LWEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var secondaryTitle: String? = nil
    var secondaryAction: (() -> Void)? = nil
    var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(targeted ? 0.16 : 0.08))
                    .frame(width: 84, height: 84)
                    .blur(radius: targeted ? 0 : 8)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
            }
            Text(targeted ? "Release to add" : title)
                .font(.title2.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                if let secondaryTitle, let secondaryAction {
                    Button(secondaryTitle, action: secondaryAction)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.18),
                                      style: StrokeStyle(lineWidth: targeted ? 2 : 1,
                                                         dash: targeted ? [] : [7, 7]))
                }
        }
        .padding(28)
    }
}

struct LWSettingRow<Content: View>: View {
    let title: String
    var help: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.callout)
            Spacer(minLength: 8)
            content
        }
        .help(help ?? "")
    }
}

struct SkeletonBlock: View {
    var height: CGFloat = 12
    var width: CGFloat? = nil
    var radius: CGFloat = 6
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.secondary.opacity(dim ? 0.09 : 0.16))
            .frame(width: width, height: height)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
    }
}
