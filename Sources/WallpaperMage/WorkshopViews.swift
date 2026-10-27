import SwiftUI
import AppKit
import Core

// Views for the Workshop and the Steam settings, built on the WorkshopModel surface in Workshop.swift. Result cards
// open the detail pane (WorkshopDetailView.swift); downloads live in their own page (DownloadsView.swift). The Steam
// tab of the Settings window is the in-app wizard (SteamWizardView.swift) plus an Advanced section.
//
// Layout stability rule: the browse task hangs off WorkshopView's root, whose identity never changes when the
// window is resized or the detail pane opens. Only a real change of the search inputs (sort, text, filters)
// restarts it, and a restart keeps the previous results on screen while the new page loads.

// MARK: - Shared pieces

private let apiKeyPage = URL(string: "https://steamcommunity.com/dev/apikey")!

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(text, forType: .string)
}

private func cardInfoLine(_ item: WorkshopItem) -> String {
    var parts: [String] = []
    if item.sizeBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) }
    if let updated = item.updated {
        parts.append(String(localized: "updated \(updated.formatted(date: .abbreviated, time: .omitted))"))
    }
    if let author = item.author { parts.append(String(localized: "by \(author)")) }
    return parts.joined(separator: " · ")
}

/// Videos 3840 pixels wide or more need a lot of memory and battery.
private func isHighResolution(_ item: WorkshopItem) -> Bool {
    guard let width = item.resolutionTag?.split(separator: " ").first.flatMap({ Int($0) }) else { return false }
    return width >= 3840
}

/// A pasted link or item number worth looking up without waiting for the button.
private func looksLikeWorkshopItem(_ text: String) -> Bool {
    if (6...20).contains(text.count), text.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
    let lowered = text.lowercased()
    return lowered.contains("filedetails") || lowered.contains("communityfilepage")
}

@MainActor
private struct FixButton: View {
    let fix: WorkshopFix
    let workshop: WorkshopModel
    let retry: () -> Void
    let openSteamSetup: () -> Void

    var body: some View { Button(title, action: run) }

    private var title: LocalizedStringKey {
        switch fix {
        case .openSteamSetup: return "Open Steam Settings"
        case .copyLoginCommand: return "Copy login command"
        case .copyBrewCommand: return "Copy brew command"
        case .copyRosettaCommand: return "Copy Rosetta command"
        case .openAPIKeyPage: return "Open the API key page"
        case .retry: return "Retry"
        }
    }

    private func run() {
        switch fix {
        case .openSteamSetup: openSteamSetup()
        case .copyLoginCommand: copyToPasteboard(workshop.loginCommand)
        case .copyBrewCommand: copyToPasteboard(workshop.brewInstallCommand)
        case .copyRosettaCommand: copyToPasteboard(workshop.rosettaInstallCommand)
        case .openAPIKeyPage: NSWorkspace.shared.open(apiKeyPage)
        case .retry: retry()
        }
    }
}

/// An error in the words of `WorkshopError`: bold orange title, secondary message, the fix button if any.
@MainActor
struct WorkshopFailureView: View {
    let error: WorkshopError
    let workshop: WorkshopModel
    let retry: () -> Void
    let openSteamSetup: () -> Void
    var dismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(error.title).font(.subheadline.weight(.bold)).foregroundStyle(.orange)
            Text(error.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if let fix = error.fix {
                    FixButton(fix: fix, workshop: workshop, retry: retry, openSteamSetup: openSteamSetup)
                }
                if let dismiss { Button("Dismiss", action: dismiss).buttonStyle(.link) }
            }
            .controlSize(.small)
        }
    }
}

/// Workshop preview pictures (an item's preview_url: a GIF when its author made an animated one), downloaded once and
/// kept while memory allows. The result cards and the detail pane share them.
@MainActor
final class WorkshopPreviews {
    static let shared = WorkshopPreviews()
    /// Longest side a preview is decoded at: enough for the widest card, and for the detail pane beside the results, on a
    /// Retina display. The detail pane covering a narrow window shows it somewhat larger.
    nonisolated private static let maxPixelSize = 720
    private let cache = NSCache<NSURL, AnimatedPicture>()
    private var loading: [URL: Task<AnimatedPicture?, Never>] = [:]

    private init() {
        // Each costs its decoded still or the bytes of its animation: a few pages of results.
        cache.totalCostLimit = 96 << 20
    }

    /// The picture when it is at hand, without waiting: a card scrolled back into view shows it in its first frame.
    func cached(_ url: URL?) -> AnimatedPicture? { url.flatMap { cache.object(forKey: $0 as NSURL) } }

    /// The picture at `url`, downloaded once however many views ask for it; nil when there is none. A download goes on
    /// when the view that asked goes away, so the picture is ready when it comes back.
    func picture(at url: URL) async -> AnimatedPicture? {
        if let cached = cached(url) { return cached }
        let task = loading[url] ?? Task.detached(priority: .userInitiated) {
            guard let data = await WorkshopKit.Import.remotePreview(url)?.data else { return nil }
            return AnimatedPicture(data: data, maxPixelSize: Self.maxPixelSize)
        }
        loading[url] = task
        let picture = await task.value
        loading[url] = nil
        if let picture { cache.setObject(picture, forKey: url as NSURL, cost: picture.cost) }
        return picture
    }
}

/// A result's preview, filling a 16:9 frame (most Workshop previews are square) and playing while it is on screen.
/// Off screen it lets go of the picture, which the cache keeps while memory allows.
@MainActor
private struct PreviewImage: View {
    let url: URL?
    @State private var picture: AnimatedPicture?
    @State private var onScreen = true

    var body: some View {
        let shown = picture ?? WorkshopPreviews.shared.cached(url)
        Rectangle().fill(Color.primary.opacity(0.05))
            .overlay {
                if let shown {
                    AnimatedPictureView(picture: shown, playing: onScreen)
                        .transition(.opacity)
                } else {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .animation(WMMotion.content, value: shown != nil)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
            .onScrollVisibilityChange(threshold: 0.01) { onScreen = $0 }
            .task(id: url) {
                picture = nil
                if let url { picture = await WorkshopPreviews.shared.picture(at: url) }
            }
            .onDisappear { picture = nil }
    }
}

@MainActor
struct WorkshopChip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        WMChip(text: text, tint: tint)
    }
}

@MainActor
private struct ChipRow: View {
    let item: WorkshopItem

    var body: some View {
        HStack(spacing: 6) {
            if let kind = item.kind.label {
                WorkshopChip(text: kind, tint: item.isImportable ? WMTheme.accent : Color.orange)
            }
            if let resolution = item.resolutionTag { WorkshopChip(text: resolution) }
            if let rating = item.ratingTag { WorkshopChip(text: rating) }
            if isHighResolution(item) {
                WorkshopChip(text: String(localized: "High resolution"), tint: .orange)
                    .help("Large videos use more memory and battery")
            }
        }
    }
}

// MARK: - Item cards

/// What a card's action area shows, from the download state and the library.
enum WorkshopCardAction {
    case download, cantPlay, inLibrary(added: Bool)
    case queued, signingIn, downloading(Double?), importing
    case failed(WorkshopError)

    static func make(item: WorkshopItem, state: WorkshopDownloadState?, inLibrary: Bool) -> WorkshopCardAction {
        switch state {
        case .queued?: return .queued
        case .signingIn?: return .signingIn
        case .downloading(let progress)?: return .downloading(progress)
        case .importing?: return .importing
        case .failed(let error)?: return .failed(error)
        case .done?: return inLibrary ? .inLibrary(added: true) : .download
        case nil: break
        }
        if inLibrary { return .inLibrary(added: false) }
        return item.isImportable ? .download : .cantPlay
    }
}

@MainActor
struct WorkshopCardActions: View {
    let item: WorkshopItem
    let action: WorkshopCardAction
    let ready: Bool          // Steam setup is complete
    let compact: Bool
    let workshop: WorkshopModel
    let openSteamSetup: () -> Void
    let showInLibrary: () -> Void

    /// Why Download is disabled until the Steam setup is complete.
    static let setupFirst = String(localized: "Finish the Steam setup in Settings first")

    var body: some View {
        switch action {
        case .download: downloadButton
        case .cantPlay: cantPlay
        case .inLibrary(let added): inLibrary(added: added)
        case .queued: progress("Waiting")
        case .signingIn: progress("Signing in to Steam", spinner: true)
        case .downloading(let value): downloading(value)
        case .importing: progress("Adding to your library", spinner: true, cancellable: false)
        case .failed(let error):
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.download(item) },
                        openSteamSetup: openSteamSetup, dismiss: { workshop.dismissDownload(item.id) })
        }
    }

    private var downloadTitle: String {
        guard item.sizeBytes > 0 else { return String(localized: "Download") }
        let size = ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)
        return String(localized: "Download · \(size)")
    }

    @ViewBuilder private var downloadButton: some View {
        if compact {
            Button { workshop.download(item) } label: {
                Label(downloadTitle, systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!ready)
            .help(ready ? "" : WorkshopCardActions.setupFirst)
        } else {
            Button { workshop.download(item) } label: {
                Label(downloadTitle, systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!ready)
            .help(ready ? "" : WorkshopCardActions.setupFirst)
        }
    }

    private var cantPlay: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button("Can’t be played") {}.disabled(true).controlSize(compact ? .small : .regular)
            Text(WorkshopError.unsupportedType(item.kind).message).font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inLibrary(added: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(added ? "Added to Library" : "In Library").font(compact ? .caption : .subheadline)
            Button("Show in Library", action: showInLibrary).buttonStyle(.link).font(compact ? .caption : .subheadline)
        }
    }

    private func downloading(_ value: Double?) -> some View {
        guard let value else { return progress("Downloading", spinner: true) }
        let clamped = min(max(value, 0), 1)
        return progress("Downloading… \(Int((clamped * 100).rounded()))%", fraction: clamped)
    }

    /// `fraction` shows a bar, `spinner` an indeterminate spinner; cancelling is offered unless `cancellable` is off.
    private func progress(_ label: LocalizedStringKey, fraction: Double? = nil, spinner: Bool = false,
                          cancellable: Bool = true) -> some View {
        HStack(spacing: 8) {
            if let fraction {
                WMProgressBar(progress: fraction, height: 4)
                    .frame(width: compact ? 90 : 150)
            }
            if spinner { ProgressView().controlSize(.small) }
            Text(label).font(.caption).foregroundStyle(.secondary)
            if cancellable {
                Button { workshop.cancelDownload(item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Cancel").accessibilityLabel("Cancel download")
            }
        }
    }
}

// MARK: - Item cards: layouts

@MainActor
private struct ResultCard<Actions: View>: View {
    let item: WorkshopItem
    let actions: Actions

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            PreviewImage(url: item.previewURL).frame(width: 232, height: 131)
                .shadow(color: .black.opacity(hovering ? 0.22 : 0.08), radius: hovering ? 16 : 10, y: 7)
            VStack(alignment: .leading, spacing: 8) {
                Text(item.title).font(.title3.weight(.semibold)).lineLimit(2)
                ChipRow(item: item)
                Text(cardInfoLine(item)).font(.caption).foregroundStyle(.secondary)
                if !item.summary.isEmpty {
                    Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }
                Spacer(minLength: 2)
                actions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(18)
        .background { glassShape(radius: WMTheme.cardRadius) }
        .scaleEffect(hovering ? 1.005 : 1)
        .animation(WMMotion.hover, value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }
}

@MainActor
private struct CompactCard<Actions: View>: View {
    let item: WorkshopItem
    let actions: Actions

    private var info: String {
        var parts: [String] = []
        if item.sizeBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) }
        if let resolution = item.resolutionTag { parts.append(resolution) }
        return parts.joined(separator: " · ")
    }

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PreviewImage(url: item.previewURL)
                .scaleEffect(hovering ? 1.02 : 1, anchor: .center)
                .animation(WMMotion.hover, value: hovering)
            Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2, reservesSpace: true)
            HStack(spacing: 5) {
                // Two at most, to keep cards tidy.
                ForEach(item.topicTags.prefix(2), id: \.self) { tag in
                    WMChip(text: tag)
                }
            }
            .frame(height: 16, alignment: .top)
            Text(info).font(.caption).foregroundStyle(.secondary)
            actions
        }
        .padding(14)
        .background { glassShape(radius: WMTheme.cardRadius) }
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }
}

// MARK: - Workshop tab

/// Workshop tab: paste field + result card, the browse grid with Wallpaper Engine's sorts and filters (needs an API
/// key) and setup banner.
@MainActor
struct WorkshopView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let openSteamSetup: () -> Void
    let openLibrary: () -> Void
    @State private var browsed = false
    @State private var detail: WorkshopItem?   // the result whose detail pane is open
    @State private var resultsScrolledDown = false   // folds the top part away (see `foldingPart`)
    @State private var foldingHeight: CGFloat = 0    // the top part's natural height

    // RootView (another file) builds this view; spelling the init out keeps the private @State from affecting it.
    init(model: SettingsModel, workshop: WorkshopModel,
         openSteamSetup: @escaping () -> Void, openLibrary: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._workshop = ObservedObject(wrappedValue: workshop)
        self.openSteamSetup = openSteamSetup
        self.openLibrary = openLibrary
    }

    // Wide windows show the detail pane next to the results; narrow ones cover the results with it.
    // The browse task is attached here — the root — so no amount of resizing or detail opening restarts it.
    var body: some View {
        GeometryReader { proxy in
            content(wide: proxy.size.width >= 760)
        }
        .animation(WMMotion.content, value: detail?.id)
        .onAppear { workshop.recheckSetup() }
        .task(id: workshop.browseKey) { await refreshBrowse() }
    }

    /// The results column keeps one place in the view tree whether or not the detail pane is open: moving it
    /// between branches would rebuild its scroll view and jump back to the top of the list. A narrow window hides it
    /// under the detail pane instead of removing it, disables it so its controls ignore the keyboard, and pauses its
    /// animated previews.
    /// Its width changes without animation, which AnchoredScrollView needs to keep the same wallpapers in view.
    @ViewBuilder private func content(wide: Bool) -> some View {
        let covered = detail != nil && !wide
        HStack(spacing: 0) {
            resultsColumn
                .animation(nil, value: detail?.id)
                .opacity(covered ? 0 : 1)
                .disabled(covered)
                .accessibilityHidden(covered)
                .environment(\.animatedPicturesPlay, !covered)
            if wide, let item = detail {
                Divider()
                detailPane(item).frame(width: 380).zIndex(1)
            }
        }
        .overlay {
            if !wide, let item = detail { detailPane(item) }
        }
    }

    private func detailPane(_ item: WorkshopItem) -> some View {
        WorkshopDetailView(model: model, workshop: workshop, item: item, close: { detail = nil },
                           openSteamSetup: openSteamSetup, openLibrary: openLibrary)
            .id(item.id)
    }

    /// The page header, the folding part and the browse controls stay put, as Home's header does; only the results
    /// below them scroll. Without an API key there are no results, and the folding part holds the whole page.
    private var resultsColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            WMPageHeader(
                title: "Workshop",
                subtitle: "Video and scene wallpapers from Steam, downloaded with your own account.")
                .padding(.horizontal, WMTheme.contentPadding)
                .padding(.top, WMTheme.pageTopPadding)
            foldingPart
            if workshop.canBrowse {
                WorkshopBrowseControls(workshop: workshop)
                    .padding(.horizontal, WMTheme.contentPadding)
                    .padding(.bottom, 8)
                results
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(WMBackground())
        .onChange(of: workshop.canBrowse) { resultsScrolledDown = false }
    }

    private var isFolded: Bool { resultsScrolledDown && workshop.canBrowse }

    /// The setup banner, the paste field and what it looked up, between the page header and the browse controls. It
    /// folds away once the results are scrolled down, leaving them the room, and unfolds when they are back at the top;
    /// it stays in the view tree meanwhile, so the paste field keeps its text and lookup.
    /// A scroll view of its own, sized to its content (`foldingHeight`): in a short window the stack gives it at most
    /// half of the free height, and a tall lookup result scrolls in it. Its padding holds the section gaps above and
    /// below it and the room for the cards' shadows, which it clips; folded, it keeps one gap.
    private var foldingPart: some View {
        let folded = isFolded
        return ScrollView {
            VStack(alignment: .leading, spacing: WMTheme.sectionSpacing) {
                if !workshop.setup.canDownload { setupBanner }
                pasteRow
                lookupSection
                if !workshop.canBrowse { keyHint }
            }
            .padding(.horizontal, WMTheme.contentPadding)
            .padding(.vertical, WMTheme.sectionSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { foldingHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: folded ? WMTheme.sectionSpacing : foldingHeight)
        .opacity(folded ? 0 : 1)
        .disabled(folded)
        .accessibilityHidden(folded)
        .environment(\.animatedPicturesPlay, !folded)
    }

    /// Anchored, so the grid keeps showing the same wallpapers, and the one whose details are open, when the detail
    /// pane narrows or widens it. Nearing the end of the grid loads the next page (WorkshopListEnd); after a failed
    /// page only Retry loads again, as retrying on every scroll would keep hitting a failing API.
    private var results: some View {
        AnchoredScrollView(order: workshop.results.map(\.id), keepingVisible: detail?.id) {
            VStack(alignment: .leading, spacing: 14) {
                browseResults
            }
            .padding([.horizontal, .bottom], WMTheme.contentPadding)
            // With the browse controls' bottom padding, the gap between them and the grid.
            .padding(.top, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onScrollGeometryChange(for: WorkshopListEnd.self, of: WorkshopListEnd.init) { _, end in
            if end.isNear, workshop.listState == .loaded { workshop.loadMore() }
        }
        .onScrollGeometryChange(for: Bool?.self, of: scrolledDown) { _, scrolledDown in
            guard let scrolledDown, scrolledDown != resultsScrolledDown else { return }
            withAnimation(WMMotion.content) { resultsScrolledDown = scrolledDown }
        }
    }

    /// Whether the results count as scrolled down, which folds the part above them: no at the top, yes a little further
    /// down, unchanged (nil) in between. Only results that would still scroll with the room folding frees count as
    /// scrolled down: shorter ones would snap back to the top as it folds, and unfold it again.
    private func scrolledDown(_ geometry: ScrollGeometry) -> Bool? {
        let offset = geometry.contentOffset.y + geometry.contentInsets.top
        if offset < 1 { return false }
        let scrollRange = geometry.contentSize.height - geometry.containerSize.height
        return offset > 12 && scrollRange > foldingHeight ? true : nil
    }

    private var setupBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Finish the Steam setup to download wallpapers.")
            Spacer()
            Button("Open Steam Settings", action: openSteamSetup)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wmGlassCard(radius: 12)
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    private var pasteRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "link")
                .foregroundStyle(.secondary)
            TextField("Paste a Workshop link or item number", text: $workshop.pastedText)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium))
                .onSubmit { workshop.lookUp() }
            if !workshop.pastedText.isEmpty {
                Button { workshop.pastedText = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Clear")
            }
        }
        .padding(14)
        .background { glassShape(radius: 15) }
        .textFieldClickArea()
        .task(id: workshop.pastedText) { await lookUpPastedText() }
    }

    /// Looks a plausible link or number up once typing or pasting has paused.
    private func lookUpPastedText() async {
        let text = workshop.pastedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeWorkshopItem(text) else { return }
        if case .found(let item) = workshop.lookup, text.contains(item.id) { return }
        try? await Task.sleep(nanoseconds: 600_000_000)
        if !Task.isCancelled { workshop.lookUp() }
    }

    @ViewBuilder private var lookupSection: some View {
        switch workshop.lookup {
        case .idle:
            if !workshop.canBrowse { emptyState }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking up").foregroundStyle(.secondary)
            }
        case .found(let item):
            ResultCard(item: item, actions: actions(for: item, compact: false))
                .contentShape(Rectangle())
                .onTapGesture { detail = item }
        case .failed(let error):
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.lookUp() }, openSteamSetup: openSteamSetup)
                .wmGlassCard()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Download wallpapers from Steam").font(.title3.weight(.semibold))
            Text("Paste a Workshop link or item number above. Video and scene wallpapers can play.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
        .background { glassShape(radius: WMTheme.cardRadius) }
    }

    private func actions(for item: WorkshopItem, compact: Bool) -> some View {
        WorkshopCardActions(item: item,
                    action: WorkshopCardAction.make(item: item, state: workshop.downloads[item.id], inLibrary: workshop.isInLibrary(item.id)),
                    ready: workshop.setup.canDownload, compact: compact, workshop: workshop,
                    openSteamSetup: openSteamSetup, showInLibrary: { showInLibrary(item) })
    }

    private func showInLibrary(_ item: WorkshopItem) {
        if let video = model.videos.first(where: { $0.workshopID == item.id }) { model.focusedID = video.id }
        openLibrary()
    }

    // MARK Browse

    /// The first run loads (or keeps) the list at once; later changes of sort, search text or filters wait
    /// 400 ms and keep the previous results on screen while the new page loads (WorkshopModel.search).
    private func refreshBrowse() async {
        if !browsed {
            browsed = true
            if workshop.listState == .idle { workshop.search() }
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if !Task.isCancelled { workshop.search(keepingResults: true) }
    }

    private var keyHint: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle")
            Text("Browsing needs a free Steam Web API key. Add one in Steam Settings, or paste a link above.")
            Spacer(minLength: 6)
            Button("Steam Settings", action: openSteamSetup).buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(14)
        .background { glassShape(radius: 12) }
    }

    @ViewBuilder private var browseResults: some View {
        if case .failed(let error) = workshop.listState, workshop.results.isEmpty {
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.search() }, openSteamSetup: openSteamSetup)
        }
        if case .failed = workshop.listState, !workshop.results.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange)
                Text("Couldn’t refresh — showing the previous results.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Retry") { workshop.search(keepingResults: true) }
                    .buttonStyle(.link).font(.caption)
            }
            .frame(maxWidth: .infinity)
        }
        if workshop.listState == .loaded, workshop.results.isEmpty {
            Text("No wallpapers match. Try other filters or another search.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if !workshop.results.isEmpty {
            resultGrid
                .opacity(workshop.listState == .loading ? 0.55 : 1)
                .animation(WMMotion.content, value: workshop.listState == .loading)
        }
        switch workshop.listState {
        case .loading:
            if workshop.results.isEmpty {
                skeletonGrid
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Refreshing").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        case .loadingMore:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        case .loadMoreFailed(let error):
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.loadMore() }, openSteamSetup: openSteamSetup)
        case .idle, .loaded, .failed:
            EmptyView()
        }
    }

    private var resultGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: WMTheme.gridSpacing)],
                  alignment: .leading, spacing: WMTheme.gridSpacing) {
            ForEach(workshop.results) { item in
                CompactCard(item: item, actions: actions(for: item, compact: true))
                    .contentShape(Rectangle())
                    .onTapGesture { detail = item }
                    .scrollAnchorItem(item.id)
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: WMTheme.gridSpacing)],
                  alignment: .leading, spacing: WMTheme.gridSpacing) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock(height: 132, radius: 12)
                    SkeletonBlock(height: 12, width: 180)
                    SkeletonBlock(height: 10, width: 110)
                }
                .padding(14)
                .background { glassShape(radius: WMTheme.cardRadius) }
            }
        }
    }
}

/// What the Workshop tab reads from its scroll view to load the next page in time. The content height is part of it so
/// that every change of the list checks again with fresh geometry, which keeps loading while a new page still leaves
/// the end in view (a tall window). A page that brings nothing new changes no grid height; the loading row below the
/// grid coming and going still does, so that row must take up height, or such a page stops the list.
private struct WorkshopListEnd: Equatable {
    let isNear: Bool
    let contentHeight: CGFloat

    init(_ geometry: ScrollGeometry) {
        contentHeight = geometry.contentSize.height
        // Less than a screen to go, so the next page usually arrives before the user gets there.
        isNear = contentHeight - geometry.visibleRect.maxY < geometry.containerSize.height
    }
}

// MARK: - Steam settings

/// The Steam tab of the Settings window: the wizard, then an Advanced section with the optional Web API key, a manual
/// SteamCMD path and the sign-in check of the download path.
@MainActor
struct SteamSetupView: View {
    @ObservedObject var workshop: WorkshopModel
    @ObservedObject var setup: SteamSetupModel
    @State private var advancedOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Download wallpapers from the Steam Workshop with your own account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                SteamWizardView(setup: setup)
                DisclosureGroup("Advanced", isExpanded: $advancedOpen) {
                    advanced
                }
                .disclosureGroupStyle(WMCardDisclosureStyle())
                .font(.callout)
                .wmGlassCard(padding: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.visible)
        .onAppear { workshop.recheckSetup() }
        .onChange(of: setup.account) { _, account in
            // The download path reads the username from the Workshop model; keep both on the signed-in name.
            if case .signedIn(let name) = account, workshop.steamUsername != name { workshop.steamUsername = name }
        }
        .task(id: [workshop.steamUsername, workshop.steamcmdPathOverride, workshop.apiKey]) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled { workshop.recheckSetup() }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 16) {
            apiKeyBlock
            toolPathBlock
            signInCheckBlock
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var apiKeyBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steam Web API key (optional)").font(.subheadline.weight(.semibold))
            HStack {
                SecureField("Web API key", text: $workshop.apiKey).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Link("Get a free key", destination: apiKeyPage)
                Button("Remove") { workshop.apiKey = "" }.disabled(workshop.apiKey.isEmpty)
            }
            Text("Only needed to browse and search. Stored on this Mac, in this app’s preferences.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var toolPathBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SteamCMD location").font(.subheadline.weight(.semibold))
            Text(workshop.setup.steamcmdPath ?? String(localized: "Not found"))
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Choose") { chooseSteamcmd() }
                Button("Use automatic") { useAutomaticPath() }.disabled(workshop.steamcmdPathOverride.isEmpty)
            }
            Text("Only needed if you already have SteamCMD somewhere else. Wallpaper Mage installs its own copy otherwise.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var signInCheckBlock: some View {
        HStack(spacing: 12) {
            Button("Check sign-in") { workshop.checkLogin() }.disabled(!canCheckLogin)
            Text(loginText).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Everything the sign-in check needs is in place.
    private var canCheckLogin: Bool {
        workshop.setup.steamcmdPath != nil && workshop.setup.rosettaOK && workshop.setup.usernameValid
    }

    private var loginText: String {
        switch workshop.setup.login {
        case .unknown: return String(localized: "Not checked yet")
        case .checking: return String(localized: "Checking")
        case .loggedIn: return String(localized: "Signed in as \(workshop.steamUsername)")
        case .needsLogin: return String(localized: "Sign in with the steps above.")
        case .failed(let error): return error.title
        }
    }

    private func chooseSteamcmd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose the steamcmd program.")
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url {
            workshop.steamcmdPathOverride = url.path
            refreshTools()
        }
    }

    private func useAutomaticPath() {
        workshop.steamcmdPathOverride = ""
        refreshTools()
    }

    private func refreshTools() {
        workshop.recheckSetup()
        setup.refresh()
    }
}
