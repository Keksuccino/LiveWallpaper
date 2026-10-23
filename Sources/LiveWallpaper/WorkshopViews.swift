import SwiftUI
import AppKit
import Core

// Views for the Workshop and Steam Setup tabs, built on the WorkshopModel surface in Workshop.swift. Result cards
// open the detail pane (WorkshopDetailView.swift). Steam Setup is the in-app wizard (SteamWizardView.swift) plus an
// Advanced section. Layout, states and microcopy: SPEC2.md 5.4 to 5.6, SPEC3.md 6.3 and 6.4.

// MARK: - Shared pieces

private let apiKeyPage = URL(string: "https://steamcommunity.com/dev/apikey")!

@MainActor
private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    _ = NSPasteboard.general.setString(text, forType: .string)
}

private extension View {
    func cardStyle() -> some View {
        padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: LWTheme.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: LWTheme.cardRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                    }
            }
    }
}

private func cardInfoLine(_ item: WorkshopItem) -> String {
    var parts: [String] = []
    if item.sizeBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file)) }
    if let updated = item.updated { parts.append("updated " + updated.formatted(date: .abbreviated, time: .omitted)) }
    if let author = item.author { parts.append("by " + author) }
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

    private var title: String {
        switch fix {
        case .openSteamSetup: return "Open Steam Setup"
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

@MainActor
private struct PreviewImage: View {
    let url: URL?

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        Image(systemName: "film").foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            }
    }
}

@MainActor
struct WorkshopChip: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        LWChip(text: text, tint: tint)
    }
}

@MainActor
private struct ChipRow: View {
    let item: WorkshopItem

    var body: some View {
        HStack(spacing: 6) {
            if item.kind != .unknown {
                WorkshopChip(text: item.kind.rawValue.capitalized, tint: item.isImportable ? Color.accentColor : Color.orange)
            }
            if let resolution = item.resolutionTag { WorkshopChip(text: resolution) }
            if let rating = item.ratingTag { WorkshopChip(text: rating) }
            if isHighResolution(item) {
                WorkshopChip(text: "High resolution", tint: .orange).help("Large videos use more memory and battery")
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

    /// Why Download is disabled until Steam Setup is complete.
    static let setupFirst = "Finish Steam Setup first"

    var body: some View {
        switch action {
        case .download: downloadButton
        case .cantPlay: cantPlay
        case .inLibrary(let added): inLibrary(added: added)
        case .queued: progress("Waiting…")
        case .signingIn: progress("Signing in to Steam…", spinner: true)
        case .downloading(let value): downloading(value)
        case .importing: progress("Adding to your library…", spinner: true, cancellable: false)
        case .failed(let error):
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.download(item) },
                        openSteamSetup: openSteamSetup, dismiss: { workshop.dismissDownload(item.id) })
        }
    }

    private var downloadButton: some View {
        let size = item.sizeBytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file) : ""
        return Button { workshop.download(item) } label: { Label("Download" + size, systemImage: "arrow.down.circle") }
            .buttonStyle(.borderedProminent)
            .controlSize(compact ? .small : .regular)
            .disabled(!ready)
            .help(ready ? "" : WorkshopCardActions.setupFirst)
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
        guard let value else { return progress("Downloading…", spinner: true) }
        let clamped = min(max(value, 0), 1)
        return progress("Downloading… \(Int((clamped * 100).rounded()))%", fraction: clamped)
    }

    /// `fraction` shows a bar, `spinner` an indeterminate spinner; cancelling is offered unless `cancellable` is off.
    private func progress(_ label: String, fraction: Double? = nil, spinner: Bool = false, cancellable: Bool = true) -> some View {
        HStack(spacing: 8) {
            if let fraction { ProgressView(value: fraction).frame(width: compact ? 80 : 140) }
            if spinner { ProgressView().controlSize(.small) }
            Text(label).font(.caption).foregroundStyle(.secondary)
            if cancellable {
                Button { workshop.cancelDownload(item.id) } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).help("Cancel").accessibilityLabel("Cancel download")
            }
        }
    }
}

@MainActor
private struct ResultCard<Actions: View>: View {
    let item: WorkshopItem
    let actions: Actions

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            PreviewImage(url: item.previewURL).frame(width: 224, height: 126)
                .shadow(color: .black.opacity(hovering ? 0.20 : 0), radius: 14, y: 7)
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
        .cardStyle()
        .scaleEffect(hovering ? 1.005 : 1)
        .animation(LWMotion.hover, value: hovering)
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
        VStack(alignment: .leading, spacing: 9) {
            PreviewImage(url: item.previewURL)
                .scaleEffect(hovering ? 1.02 : 1)
                .animation(LWMotion.hover, value: hovering)
            Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2, reservesSpace: true)
            Text(info).font(.caption).foregroundStyle(.secondary)
            actions
        }
        .cardStyle()
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
    }
}

// MARK: - Workshop tab

/// Workshop tab: paste field + result card, optional browse grid (needs an API key), setup banner.
@MainActor
struct WorkshopView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let openSteamSetup: () -> Void
    let openLibrary: () -> Void
    @State private var browsed = false
    @State private var detail: WorkshopItem?   // the result whose detail pane is open

    // RootView (another file) builds this view; spelling the init out keeps the private @State from affecting it.
    init(model: SettingsModel, workshop: WorkshopModel,
         openSteamSetup: @escaping () -> Void, openLibrary: @escaping () -> Void) {
        self._model = ObservedObject(wrappedValue: model)
        self._workshop = ObservedObject(wrappedValue: workshop)
        self.openSteamSetup = openSteamSetup
        self.openLibrary = openLibrary
    }

    // Wide windows show the detail pane next to the results; narrow ones replace the results with it.
    var body: some View {
        GeometryReader { proxy in
            content(wide: proxy.size.width >= 760)
        }
        .animation(LWMotion.content, value: detail?.id)
        .onAppear { workshop.recheckSetup() }
    }

    @ViewBuilder private func content(wide: Bool) -> some View {
        if let item = detail {
            if wide {
                HStack(spacing: 0) {
                    resultsColumn
                    Divider()
                    detailPane(item).frame(width: 380)
                }
            } else {
                detailPane(item)
            }
        } else {
            resultsColumn
        }
    }

    private func detailPane(_ item: WorkshopItem) -> some View {
        WorkshopDetailView(model: model, workshop: workshop, item: item, close: { detail = nil },
                           openSteamSetup: openSteamSetup, openLibrary: openLibrary)
            .id(item.id)
    }

    private var resultsColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steam Workshop").font(.system(size: 30, weight: .semibold))
                    Text("Download video and scene wallpapers with your own Steam account.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !workshop.setup.canDownload { setupBanner }
                pasteRow
                lookupSection
                if workshop.canBrowse { browseSection } else { keyHint }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var setupBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Finish the Steam setup to download wallpapers.")
            Spacer()
            Button("Open Steam Setup", action: openSteamSetup)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.25), lineWidth: 1)
                }
        }
    }

    private var pasteRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                TextField("Paste a Workshop link or item number", text: $workshop.pastedText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17, weight: .medium))
                    .onSubmit { workshop.lookUp() }
                if !workshop.pastedText.isEmpty {
                    Button { workshop.pastedText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear")
                }
                Button { paste() } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Paste from the clipboard")
                .accessibilityLabel("Paste from the clipboard")
                Button("Look Up") { workshop.lookUp() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(workshop.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
            }
            Text("Paste a link from the Steam Workshop and it looks up automatically.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
        .task(id: workshop.pastedText) { await lookUpPastedText() }
    }

    private func paste() {
        if let text = NSPasteboard.general.string(forType: .string) { workshop.pastedText = text }
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
                Text("Looking up…").foregroundStyle(.secondary)
            }
        case .found(let item):
            ResultCard(item: item, actions: actions(for: item, compact: false))
                .contentShape(Rectangle())
                .onTapGesture { detail = item }
        case .failed(let error):
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.lookUp() }, openSteamSetup: openSteamSetup)
                .cardStyle()
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
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                }
        }
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

    // MARK: Browse

    private var keyHint: some View {
        HStack(spacing: 9) {
            Image(systemName: "info.circle")
            Text("Browsing needs a free Steam Web API key. Add one in Steam Setup, or paste a link above.")
            Spacer(minLength: 6)
            Button("Steam Setup", action: openSteamSetup).buttonStyle(.link)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
        }
    }

    private var browseSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Browse").font(.title3)
            browseControls
            browseResults
        }
        .task(id: "\(workshop.sort.rawValue)|\(workshop.searchText)|\(workshop.includeMature)") { await refreshBrowse() }
    }

    /// The first run loads (or keeps) the list at once; later changes of sort, search text or rating wait 400 ms.
    private func refreshBrowse() async {
        if !browsed {
            browsed = true
            if workshop.listState == .idle { workshop.search() }
            return
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
        if !Task.isCancelled { workshop.search() }
    }

    private var browseControls: some View {
        HStack(spacing: 10) {
            Menu {
                ForEach(WorkshopSort.allCases) { sort in
                    Button(sort.label) { workshop.sort = sort }
                }
            } label: {
                Label(workshop.sort.label, systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search video wallpapers", text: $workshop.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                    }
            }

            Toggle("Mature", isOn: $workshop.includeMature)
                .toggleStyle(.checkbox)
                .help("Include questionable and mature items")
        }
    }

    @ViewBuilder private var browseResults: some View {
        if case .failed(let error) = workshop.listState {
            WorkshopFailureView(error: error, workshop: workshop, retry: { workshop.search() }, openSteamSetup: openSteamSetup)
        }
        if workshop.listState == .loaded, workshop.results.isEmpty {
            Text("No video wallpapers found.").font(.callout).foregroundStyle(.secondary)
        }
        if !workshop.results.isEmpty { resultGrid }
        if workshop.listState == .loading {
            if workshop.results.isEmpty {
                skeletonGrid
            } else {
                ProgressView().controlSize(.small)
            }
        } else if workshop.canLoadMore {
            Button("Load More") { workshop.loadMore() }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
        }
    }

    private var resultGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: LWTheme.gridSpacing)],
                  alignment: .leading, spacing: LWTheme.gridSpacing) {
            ForEach(workshop.results) { item in
                CompactCard(item: item, actions: actions(for: item, compact: true))
                    .contentShape(Rectangle())
                    .onTapGesture { detail = item }
            }
        }
    }

    private var skeletonGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: LWTheme.gridSpacing)],
                  alignment: .leading, spacing: LWTheme.gridSpacing) {
            ForEach(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 9) {
                    SkeletonBlock(height: 132, radius: 10)
                    SkeletonBlock(height: 12, width: 180)
                    SkeletonBlock(height: 10, width: 110)
                }
                .padding(18)
                .background {
                    RoundedRectangle(cornerRadius: LWTheme.cardRadius, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                }
            }
        }
    }
}

// MARK: - Steam Setup tab

/// Steam Setup tab: the wizard, then an Advanced section with the optional Web API key, a manual SteamCMD path
/// and the sign-in check of the download path.
@MainActor
struct SteamSetupView: View {
    @ObservedObject var workshop: WorkshopModel
    @ObservedObject var setup: SteamSetupModel
    @State private var advancedOpen = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Steam Setup").font(.system(size: 30, weight: .semibold))
                    Text("Download wallpapers from the Steam Workshop with your own account.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                SteamWizardView(setup: setup)
                DisclosureGroup("Advanced", isExpanded: $advancedOpen) {
                    advanced.padding(.top, 10)
                }
                .font(.callout)
                .cardStyle()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { workshop.recheckSetup() }
        .onChange(of: setup.account) { account in
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
            Text(workshop.setup.steamcmdPath ?? "Not found")
                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            HStack {
                Button("Choose…") { chooseSteamcmd() }
                Button("Use automatic") { useAutomaticPath() }.disabled(workshop.steamcmdPathOverride.isEmpty)
            }
            Text("Only needed if you already have SteamCMD somewhere else. Live Wallpaper installs its own copy otherwise.")
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
        case .unknown: return "Not checked yet"
        case .checking: return "Checking…"
        case .loggedIn: return "Signed in as \(workshop.steamUsername)"
        case .needsLogin: return "Sign in with the steps above."
        case .failed(let error): return error.title
        }
    }

    private func chooseSteamcmd() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the steamcmd program."
        panel.prompt = "Choose"
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
