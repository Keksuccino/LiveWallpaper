import SwiftUI
import AppKit

// The Workshop browser's controls above its results: the search field and the sort menu, then a capsule per filter of
// Wallpaper Engine's browser (type, age rating, resolution, tags, show only) whose popover switches its tags on and off,
// and Reset Filters while the filters differ from the standard ones. Both rows wrap rather than switch layouts, so the
// search field keeps its focus and an open popover its capsule while what the rows show changes. NSFW wallpapers come
// on only after a birthdate check (BirthdateDialog, WorkshopAgeCheck).

private let contentPreferencesPage = URL(string: "https://store.steampowered.com/account/preferences/")!

@MainActor
struct WorkshopBrowseControls: View {
    @ObservedObject var workshop: WorkshopModel
    @State private var askingBirthdate = false

    var body: some View {
        // The gaps of Home's library title row: 10 between controls, `chipSpacing` within a group of them, 14 between
        // its rows.
        VStack(alignment: .leading, spacing: 14) {
            WrappingRows(spacing: 10, lineSpacing: 10) {
                WMSearchField(prompt: "Search wallpapers", text: $workshop.searchText)
                    .frame(width: 260)
                WMSortMenu(title: "Sort By", selection: $workshop.sort, options: WorkshopSort.allCases, label: \.label)
                    .help("Order of the browse grid")
            }
            WrappingRows(spacing: WMTheme.chipSpacing, lineSpacing: 10) {
                typeFilter
                ratingFilter
                resolutionFilter
                genreFilter
                showOnlyFilter
                if workshop.filters != .standard {
                    resetButton
                        .wrappingGap(10)
                        .transition(.opacity)
                }
            }
        }
        // The sort menu is as wide as its sort and Reset Filters comes and goes with the filters: the rows move their
        // other controls over smoothly.
        .animation(WMMotion.content, value: workshop.sort)
        .animation(WMMotion.content, value: workshop.filters)
    }

    // MARK: Filters

    private var typeFilter: some View {
        WMFilterMenu(title: String(localized: "Type")) {
            FilterPopover {
                TagChecklist(filters: $workshop.filters, group: .type)
                Divider()
                TagChecklist(filters: $workshop.filters, group: .category)
                Text(WorkshopError.unsupportedType(.unknown).message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .help("Kinds of wallpapers to show")
    }

    private var ratingFilter: some View {
        WMFilterMenu(title: String(localized: "Age Rating")) {
            RatingPopover(filters: $workshop.filters) { askingBirthdate = true }
        }
        .help("Age ratings to show")
        .sheet(isPresented: $askingBirthdate) {
            BirthdateDialog { workshop.filters.set([WorkshopAgeCheck.tag], in: .rating, on: true) }
        }
    }

    private var resolutionFilter: some View {
        WMFilterMenu(title: String(localized: "Resolution")) {
            FilterPopover {
                HStack(spacing: 12) {
                    FilterHeading(title: String(localized: "Resolution"))
                    Spacer(minLength: 16)
                    Button("My Displays", action: fitDisplays)
                        .controlSize(.small)
                        .help("Show the resolutions that look sharp on your displays")
                    AllNoneButtons(filters: $workshop.filters, group: .resolution,
                                   tags: WorkshopFilterGroup.resolution.tags)
                }
                Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 18) {
                    let sections = WorkshopTagSection.resolutions
                    ForEach(Array(stride(from: 0, to: sections.count, by: 3)), id: \.self) { start in
                        GridRow {
                            ForEach(sections[start..<min(start + 3, sections.count)]) { section in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(spacing: 12) {
                                        Text(section.title ?? "")
                                            .font(.subheadline.weight(.semibold))
                                            .fixedSize()
                                        Spacer(minLength: 8)
                                        AllNoneButtons(filters: $workshop.filters, group: .resolution,
                                                       tags: section.tags)
                                    }
                                    TagChecklist(filters: $workshop.filters, group: .resolution, tags: section.tags)
                                }
                            }
                        }
                    }
                }
            }
        }
        .help("Resolutions to show")
    }

    private var genreFilter: some View {
        WMFilterMenu(title: String(localized: "Tags")) {
            FilterPopover {
                HStack(spacing: 12) {
                    FilterHeading(title: String(localized: "Tags"))
                    Spacer(minLength: 16)
                    AllNoneButtons(filters: $workshop.filters, group: .genre, tags: WorkshopFilterGroup.genre.tags)
                }
                TagChecklist(filters: $workshop.filters, group: .genre, columns: 3)
            }
        }
        .help("Genres to show")
    }

    private var showOnlyFilter: some View {
        WMFilterMenu(title: String(localized: "Show Only")) {
            FilterPopover {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(WorkshopFilters.showOnlyTags, id: \.self) { tag in
                        Toggle(WorkshopTags.label(tag), isOn: Binding(
                            get: { workshop.filters.required.contains(tag) },
                            set: { workshop.filters.setRequired(tag, $0) }))
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
        .help("Show only wallpapers that have all of these")
    }

    private var resetButton: some View {
        Button { workshop.filters = .standard } label: {
            Label("Reset Filters", systemImage: "arrow.counterclockwise")
                .font(.callout.weight(.medium))
                .padding(.vertical, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Go back to the standard filters")
    }

    /// Lets through the resolutions that look sharp on the connected displays.
    private func fitDisplays() {
        let sizes = NSScreen.screens.compactMap { $0.displayNumber.flatMap(nativePixelSize(of:)) }
        let fitting = WorkshopTags.resolutions(fitting: sizes)
        let tags = WorkshopFilterGroup.resolution.tags
        workshop.filters.set(tags, in: .resolution, on: false)
        workshop.filters.set(tags.filter(fitting.contains), in: .resolution, on: true)
    }
}

/// A filter's popover: its choices, padded.
private struct FilterPopover<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(16)
            .fixedSize()
    }
}

private struct FilterHeading: View {
    let title: String

    var body: some View {
        Text(title).font(.headline)
    }
}

/// Checkboxes that switch tags of a filter group on and off, in `columns` columns filled from top to bottom. A tag
/// comes on only when `mayTurnOn` lets it, which can ask the user first instead.
private struct TagChecklist: View {
    @Binding var filters: WorkshopFilters
    let group: WorkshopFilterGroup
    var tags: [String]? = nil
    var columns = 1
    var mayTurnOn: (String) -> Bool = { _ in true }

    var body: some View {
        let tags = tags ?? group.tags
        let perColumn = Int((Double(tags.count) / Double(columns)).rounded(.up))
        HStack(alignment: .top, spacing: 28) {
            ForEach(Array(stride(from: 0, to: tags.count, by: max(perColumn, 1))), id: \.self) { start in
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(tags[start..<min(start + perColumn, tags.count)], id: \.self) { tag in
                        Toggle(WorkshopTags.label(tag), isOn: Binding(
                            get: { filters.isOn(tag, in: group) },
                            set: { on in
                                guard !on || mayTurnOn(tag) else { return }
                                filters.set([tag], in: group, on: on)
                            }))
                    }
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// The Age Rating popover. NSFW comes on at once for a remembered adult; otherwise switching it on closes the popover
/// and asks for the birthdate (`askBirthdate`, which shows `BirthdateDialog`).
private struct RatingPopover: View {
    @Binding var filters: WorkshopFilters
    let askBirthdate: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        FilterPopover {
            TagChecklist(filters: $filters, group: .rating, mayTurnOn: { tag in
                guard tag == WorkshopAgeCheck.tag, !WorkshopAgeCheck.isConfirmedAdult else { return true }
                dismiss()
                askBirthdate()
                return false
            })
            Divider()
            Link(destination: contentPreferencesPage) {
                Label("Steam Content Preferences", systemImage: "arrow.up.forward.square")
            }
            .font(.callout)
            .help("Your Steam account’s own settings for mature content")
        }
    }
}

/// Switches all of `tags` on or off.
private struct AllNoneButtons: View {
    @Binding var filters: WorkshopFilters
    let group: WorkshopFilterGroup
    let tags: [String]

    var body: some View {
        HStack(spacing: 10) {
            Button("All") { filters.set(tags, in: group, on: true) }
                .disabled(tags.allSatisfy { filters.isOn($0, in: group) })
            Button("None") { filters.set(tags, in: group, on: false) }
                .disabled(!tags.contains { filters.isOn($0, in: group) })
        }
        .buttonStyle(.link)
        .font(.caption)
        .fixedSize()
    }
}
