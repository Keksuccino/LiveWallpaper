import SwiftUI
import AppKit
import Core

// The shared visual language for the Settings app. Keep every custom colour, radius, curve and
// reusable surface here so the library, Workshop and Steam settings feel like one product.
//
// The look: soft ambient colour behind everything, translucent "liquid glass" surfaces on top with a
// light-catching top edge, one accent gradient used sparingly, and quiet typography that leans on
// weight and spacing. Materials respect Reduce Transparency; every animation respects Reduce Motion.

// MARK: - Tokens

enum WMTheme {
    static let contentPadding: CGFloat = 28
    static let cardRadius: CGFloat = 18
    static let panelRadius: CGFloat = 22
    static let sidebarWidth: CGFloat = 236
    static let inspectorWidth: CGFloat = 330
    static let gridSpacing: CGFloat = 20
    static let cardMinWidth: CGFloat = 252
    static let sectionSpacing: CGFloat = 26

    /// Hairline used on every glass edge: a light top and a shadowed bottom, in one pass.
    static let edgeGradient = LinearGradient(
        stops: [
            .init(color: .white.opacity(0.28), location: 0),
            .init(color: .white.opacity(0.04), location: 0.35),
            .init(color: .black.opacity(0.10), location: 1),
        ],
        startPoint: .top, endPoint: .bottom)
}

enum WMMotion {
    static let hover = Animation.easeOut(duration: 0.16)
    static let select = Animation.spring(response: 0.28, dampingFraction: 0.86)
    static let hero = Animation.spring(response: 0.42, dampingFraction: 0.88)
    static let panel = Animation.easeInOut(duration: 0.26)
    static let content = Animation.easeInOut(duration: 0.22)
    static let success = Animation.spring(response: 0.36, dampingFraction: 0.72)
}

// MARK: - Ambient background

/// The page background every content area sits on. Deliberately plain: the window colour and nothing else.
/// The depth in this app comes from the glass surfaces and their hairlines, not from colour washes.
struct WMBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

// MARK: - Surfaces

/// The content surface: a translucent card with a light-catching top edge and a soft shadow. This is the
/// app's glass — solid fill when the user asked for reduced transparency.
struct WMCard<Content: View>: View {
    var padding: CGFloat = 16
    var radius: CGFloat = WMTheme.cardRadius
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { glassShape(radius: radius) }
    }
}

/// One glass shape used by cards, banners and rows: material fill, top sheen, gradient hairline, shadow.
@ViewBuilder
func glassShape(radius: CGFloat, cornerStyle: RoundedCornerStyle = .continuous,
                fill: some ShapeStyle = AnyShapeStyle(.regularMaterial)) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: cornerStyle)
    ZStack {
        shape.fill(fill)
        LinearGradient(colors: [.white.opacity(0.16), .clear],
                       startPoint: .top, endPoint: .center)
            .clipShape(shape)
    }
    .overlay(shape.strokeBorder(WMTheme.edgeGradient, lineWidth: 1))
    .shadow(color: .black.opacity(0.08), radius: 12, y: 5)
}

extension View {
    /// Wraps the view in the standard glass card.
    func wmGlassCard(padding cardPadding: CGFloat = 16, radius: CGFloat = WMTheme.cardRadius) -> some View {
        self.padding(cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { glassShape(radius: radius) }
    }
}

/// Floating glass for the navigation/transport layer only (hero controls, status popover, pills).
/// Real Liquid Glass; with Reduce Transparency on, an opaque panel with a hairline border.
struct GlassPanel<Content: View>: View {
    var radius: CGFloat = 18
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay {
                    shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
        } else {
            content
                .glassEffect(.regular, in: shape)
        }
    }
}

// MARK: - Page header

/// The big page title and a quiet subtitle, used to open every page. Typography-led: no icons, no colour.
struct WMPageHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 30, weight: .bold))
                    .kerning(-0.4)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing()
        }
        .padding(.bottom, 2)
    }
}

extension WMPageHeader where Trailing == EmptyView {
    /// Header without trailing actions.
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() })
    }
}

// MARK: - Inspector pieces

struct InspectorSection<Content: View>: View {
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
            }
            content
        }
    }
}

// MARK: - Chips

struct WMChip: View {
    let text: String
    var tint: Color? = nil
    var filled: Bool = false
    var icon: String? = nil
    var selected: Bool = false

    private var color: Color { tint ?? .secondary }

    var body: some View {
        HStack(spacing: 3) {
            if let icon { Image(systemName: icon).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(filled || selected ? Color.white : color)
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background {
            if selected {
                Capsule().fill(Color.accentColor)
            } else {
                Capsule().fill(filled ? color : color.opacity(0.13))
            }
        }
        .overlay {
            if !filled && !selected {
                Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5)
            }
        }
    }
}

/// A tappable capsule used for topic chips and filter segments. Text only, system accent when selected.
struct WMTopicChip: View {
    let title: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.72))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule().fill(Color.accentColor)
                    } else {
                        Capsule()
                            .fill(.regularMaterial)
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(WMMotion.hover, value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Status

struct StatusDot: View {
    let color: Color
    /// A ring keeps growing out of the dot (not with Reduce Motion).
    var pulsing = false
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var pulses: Bool { pulsing && !reduceMotion }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay {
                if pulses {
                    Circle().stroke(color.opacity(0.45), lineWidth: 1)
                        .scaleEffect(on ? 2.1 : 0.9)
                        .opacity(on ? 0 : 1)
                }
            }
            .animation(pulses ? .easeOut(duration: 1.2).repeatForever(autoreverses: false) : .default, value: on)
            .onAppear { on = pulses }
            .onChange(of: pulses) { _, newValue in on = newValue }
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
            if size >= 26 {
                Text(Int((min(max(progress, 0), 1) * 100).rounded()), format: .number)
                    .font(.system(size: 9, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Progress \(Int((min(max(progress, 0), 1) * 100).rounded())) percent")
    }
}

/// A chunky linear progress bar for downloads. `progress` nil = indeterminate (a travelling highlight).
struct WMProgressBar: View {
    let progress: Double?
    var height: CGFloat = 6
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelling = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.10))
                if let progress {
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(height, min(max(progress, 0), 1) * proxy.size.width))
                        .animation(.easeOut(duration: 0.2), value: progress)
                } else {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.75))
                        .frame(width: proxy.size.width * 0.3)
                        .offset(x: travelling ? proxy.size.width * 0.7 : 0)
                        .animation(reduceMotion ? nil
                                   : .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                                   value: travelling)
                }
            }
        }
        .frame(height: height)
        .onAppear { travelling = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Search field

/// Glass capsule search field with icon, clear button and an escape-to-clear shortcut.
struct WMSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background {
            Capsule()
                .fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
        }
        .frame(maxWidth: 260)
    }
}

// MARK: - View helpers

extension View {
    func hoverLift(_ enabled: Bool = true) -> some View {
        modifier(HoverLiftModifier(enabled: enabled))
    }

    /// A fixed inspector panel on the trailing side, always shown. Like the sidebar it reaches up into the toolbar strip,
    /// which has no items above it (a page using it hides the toolbar's background there, and its content needs top
    /// padding for the strip). SwiftUI's `inspector` would take over the toolbar's trailing items (the search field).
    func wmInspectorPanel<Inspector: View>(@ViewBuilder _ inspector: () -> Inspector) -> some View {
        HStack(spacing: 0) {
            frame(maxWidth: .infinity, maxHeight: .infinity)
            Group {
                Divider()
                inspector()
                    .frame(width: WMTheme.inspectorWidth)
                    .frame(maxHeight: .infinity)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
    }
}

extension View {
    /// For the standard controls in the window's toolbar. SwiftUI creates them a moment before the window becomes
    /// key and then does not redraw them, so they keep the dimmed look of an inactive window until the pointer passes
    /// over them. A new identity whenever the window's active state changes has SwiftUI draw them afresh. Not for a
    /// control with state of its own (a popover would close whenever it takes the key window).
    func redrawnOnWindowActivation() -> some View {
        modifier(ActiveStateRedrawModifier())
    }
}

private struct ActiveStateRedrawModifier: ViewModifier {
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content.id(activeState)
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
            .animation(WMMotion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Thumbnails

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
    var cornerRadius: CGFloat = 12

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.05))

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
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: [item.path, item.previewPath ?? ""]) {
            let loaded = await ThumbnailCache.shared.image(for: item)
            withAnimation(.easeInOut(duration: 0.2)) { image = loaded }
        }
    }
}

// MARK: - Empty states

/// A drop-in empty state used by the library and Workshop. One card: the dashed border and the surface
/// are the same rounded rectangle, so the border always contains everything inside it.
struct WMEmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var actionTitle: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil
    var secondaryTitle: LocalizedStringKey? = nil
    var secondaryAction: (() -> Void)? = nil
    var targeted = false

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.primary.opacity(targeted ? 0.10 : 0.06))
                    .frame(width: 84, height: 84)
                Image(systemName: icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(targeted ? Color.accentColor : Color.secondary)
                    .symbolRenderingMode(.hierarchical)
            }
            Text(targeted ? "Release to add" : title)
                .font(.title3.weight(.semibold))
            // Never pin this text to its full wrapped height (`fixedSize(vertical:)`): while sizing the window and its
            // split columns, SwiftUI measures the card at a very narrow width, so a pinned text reports a huge minimum
            // height. Next to the Library inspector, AppKit then re-solves the window's constraints until it throws
            // ("more Update Constraints in Window passes than there are views") and the app terminates at launch (seen
            // on macOS 27). Unpinned, the text still wraps in full: the card always gets the height it asks for.
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
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
        .padding(34)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
        .background { glassShape(radius: 24) }
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.22),
                              style: StrokeStyle(lineWidth: targeted ? 2 : 1,
                                                 dash: targeted ? [] : [6, 6]))
                .animation(WMMotion.hover, value: targeted)
        }
    }
}

// MARK: - Settings rows

struct WMSettingRow<Content: View>: View {
    let title: LocalizedStringKey
    var help: LocalizedStringKey? = nil
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            content
        }
        .help(help.map { Text($0) } ?? Text(verbatim: ""))
    }
}

/// An on/off setting: the label leading (wrapping in a narrow column), a small switch trailing.
struct WMSwitchRow<Label: View>: View {
    @Binding var isOn: Bool
    /// The label's words for VoiceOver: the switch itself shows no label.
    let accessibilityLabel: Text
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack {
            label().fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Toggle(isOn: $isOn) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(accessibilityLabel)
        }
    }
}

extension WMSwitchRow where Label == Text {
    /// A row labelled `title`.
    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.init(isOn: isOn, accessibilityLabel: Text(title)) { Text(title) }
    }
}

extension View {
    /// A control beside a label in a narrow column (the inspector): its natural width, but never more than
    /// `maxWidth`, truncating longer content (a long choice, a long translation) so the column never grows. The label
    /// beside it wraps instead.
    func columnControl(maxWidth: CGFloat = WMTheme.inspectorWidth / 2) -> some View {
        ViewThatFits(in: .horizontal) {
            fixedSize()
            self
        }
        .frame(maxWidth: maxWidth, alignment: .trailing)
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
