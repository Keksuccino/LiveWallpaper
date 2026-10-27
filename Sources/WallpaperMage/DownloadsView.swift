import SwiftUI
import AppKit
import Core

// The Downloads page: every Workshop download the app has tracked, split into what is running now and
// what has settled. The entries come from WorkshopModel.downloadEntries, which keeps the item info even
// after the results grid has moved on, so progress survives navigation and window resizing.

@MainActor
struct DownloadsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var workshop: WorkshopModel
    let openLibrary: () -> Void
    let openWorkshop: () -> Void

    private var entries: [WorkshopDownloadEntry] { workshop.downloadEntries }
    private var active: [WorkshopDownloadEntry] { entries.filter(\.phase.isActive) }
    private var settled: [WorkshopDownloadEntry] { entries.filter { !$0.phase.isActive } }

    /// The page header stays put, as on Home; only the downloads below it scroll.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, WMTheme.contentPadding)
                .padding(.top, WMTheme.pageTopPadding)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: WMTheme.sectionSpacing) {
                    if entries.isEmpty {
                        emptyState
                    } else {
                        if !active.isEmpty { activeSection }
                        if !settled.isEmpty { settledSection }
                    }
                }
                .padding([.horizontal, .bottom], WMTheme.contentPadding)
                // With the header's bottom padding, the usual gap between sections.
                .padding(.top, WMTheme.sectionSpacing - 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .background(WMBackground())
        .animation(WMMotion.content, value: entries.map(\.id))
    }

    // MARK: Header

    private var header: some View {
        WMPageHeader(
            title: "Downloads",
            subtitle: headerSubtitle,
            trailing: {
                if !settled.filter(\.phase.isDone).isEmpty {
                    Button("Clear Finished") {
                        for entry in settled where entry.phase.isDone { workshop.dismissDownload(entry.id) }
                    }
                    .controlSize(.small)
                }
            })
    }

    private var headerSubtitle: LocalizedStringKey {
        switch active.count {
        case 0: return "Workshop downloads appear here while they run."
        case 1: return "One wallpaper downloading · the rest of the app stays free to use."
        default: return "\(active.count) wallpapers queued · they download one at a time."
        }
    }

    private var emptyState: some View {
        WMEmptyState(
            icon: "arrow.down.circle",
            title: "Nothing downloading",
            actionTitle: "Browse the Workshop",
            action: openWorkshop)
    }

    // MARK: Sections

    private var activeSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("In progress", count: active.count)
            VStack(spacing: 10) {
                ForEach(active) { entry in
                    DownloadRow(entry: entry, queuePosition: workshop.queuePosition(of: entry.id),
                                workshop: workshop, model: model, openLibrary: openLibrary)
                }
            }
        }
    }

    private var settledSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Finished", count: settled.count)
            VStack(spacing: 10) {
                ForEach(settled) { entry in
                    DownloadRow(entry: entry, queuePosition: nil,
                                workshop: workshop, model: model, openLibrary: openLibrary)
                }
            }
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey, count: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Text(count, format: .number)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }
}

private extension WorkshopDownloadPhase {
    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}

// MARK: - Row

@MainActor
private struct DownloadRow: View {
    let entry: WorkshopDownloadEntry
    let queuePosition: Int?
    @ObservedObject var workshop: WorkshopModel
    @ObservedObject var model: SettingsModel
    let openLibrary: () -> Void
    @State private var hovering = false

    private var item: WorkshopItem { entry.item }
    private var phase: WorkshopDownloadPhase { entry.phase }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            thumbnail

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
                if phase.isActive { progressBar }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
        }
        .padding(14)
        .background { glassShape(radius: WMTheme.cardRadius) }
        .overlay {
            RoundedRectangle(cornerRadius: WMTheme.cardRadius, style: .continuous)
                .strokeBorder(hovering ? Color.primary.opacity(0.10) : .clear, lineWidth: 1)
        }
        .animation(WMMotion.hover, value: hovering)
        .onHover { hovering = $0 }
    }

    // MARK: Pieces

    private var thumbnail: some View {
        AsyncImage(url: item.previewURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.05))
                    Image(systemName: item.kind == .scene ? "sparkles" : "film")
                        .font(.system(size: 16))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: 112, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var phaseText: String {
        switch phase {
        case .queued(let position):
            guard position > 1, let place = Self.ordinal.string(from: position as NSNumber) else {
                return String(localized: "Waiting")
            }
            return String(localized: "Waiting · \(place) in queue")
        case .signingIn: return String(localized: "Signing in to Steam")
        case .downloading(let progress):
            guard let progress else { return String(localized: "Downloading") }
            return String(localized: "Downloading · \(Int((min(max(progress, 0), 1) * 100).rounded()))%")
        case .importing: return String(localized: "Adding to your library")
        case .done: return String(localized: "Added to your library")
        case .failed(let error): return error.title
        }
    }

    /// "1st", "2nd", ... in the user's language.
    private static let ordinal: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter
    }()

    private var statusLine: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(phaseText)
                .font(.caption)
                .foregroundStyle(isFailed ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.secondary))
            if item.sizeBytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: item.sizeBytes, countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let kind = kindChip { kindChipView(kind) }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var statusIcon: some View {
        switch phase {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
        case .queued:
            Image(systemName: "clock").foregroundStyle(.tertiary).font(.caption)
        case .signingIn, .downloading, .importing:
            StatusDot(color: WMTheme.accent, pulsing: true)
        }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    private var kindChip: (text: String, tint: Color)? {
        item.kind.label.map { ($0, item.isImportable ? WMTheme.accent : Color.orange) }
    }

    @ViewBuilder private func kindChipView(_ chip: (text: String, tint: Color)) -> some View {
        WMChip(text: chip.text, tint: chip.tint)
    }

    @ViewBuilder private var progressBar: some View {
        if case .downloading(let progress) = phase {
            WMProgressBar(progress: progress)
        } else {
            WMProgressBar(progress: nil)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch phase {
        case .queued:
            cancelButton("Remove from queue")
        case .signingIn, .downloading:
            cancelButton("Cancel download")
        case .importing:
            // The copy into the library is short and not interruptible.
            ProgressView().controlSize(.small)
        case .done:
            HStack(spacing: 8) {
                Button("Show in Library", action: showInLibrary)
                    .controlSize(.small)
                Button {
                    workshop.dismissDownload(entry.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear from the list")
                .opacity(hovering ? 1 : 0.45)
            }
        case .failed:
            HStack(spacing: 8) {
                Button("Retry") { workshop.download(item) }
                    .controlSize(.small)
                    .disabled(!item.isImportable)
                Button {
                    workshop.dismissDownload(entry.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear from the list")
                .opacity(hovering ? 1 : 0.45)
            }
        }
    }

    private func cancelButton(_ help: LocalizedStringKey) -> some View {
        Button {
            workshop.cancelDownload(entry.id)
        } label: {
            Image(systemName: "xmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private func showInLibrary() {
        if let video = model.videos.first(where: { $0.workshopID == item.id }) { model.focusedID = video.id }
        openLibrary()
    }
}
