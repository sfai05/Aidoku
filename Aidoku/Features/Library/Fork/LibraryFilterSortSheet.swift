//
//  LibraryFilterSortSheet.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import SwiftUI

struct LibraryFilterSortSheet: View {
    @ObservedObject var state: LibraryFilterSortState
    let resolveSourceName: (String) -> String
    let onToggleFilter: (LibraryFilter.FilterMethod, String?) -> Void
    let onClearFilters: () -> Void
    let onSelectSort: (LibraryViewModel.SortMethod) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var isSourcesExpanded: Bool
    @State private var isCategoriesExpanded: Bool

    init(
        state: LibraryFilterSortState,
        resolveSourceName: @escaping (String) -> String,
        onToggleFilter: @escaping (LibraryFilter.FilterMethod, String?) -> Void,
        onClearFilters: @escaping () -> Void,
        onSelectSort: @escaping (LibraryViewModel.SortMethod) -> Void
    ) {
        self.state = state
        self.resolveSourceName = resolveSourceName
        self.onToggleFilter = onToggleFilter
        self.onClearFilters = onClearFilters
        self.onSelectSort = onSelectSort

        let availableSources = LibraryFilterSortHelpers.mergedFilterOptions(
            available: state.sourceKeys,
            activeFilters: state.filters,
            method: .source
        )
        let availableCategories = LibraryFilterSortHelpers.mergedFilterOptions(
            available: state.categories,
            activeFilters: state.filters,
            method: .category
        )
        self._isSourcesExpanded = State(
            initialValue: availableSources.count <= 8 || state.filters.contains { $0.type == .source }
        )
        self._isCategoriesExpanded = State(
            initialValue: availableCategories.count <= 8 || state.filters.contains { $0.type == .category }
        )
    }

    private var mergedSourceKeys: [String] {
        LibraryFilterSortHelpers.mergedFilterOptions(
            available: state.sourceKeys,
            activeFilters: state.filters,
            method: .source
        )
    }

    private var mergedCategories: [String] {
        LibraryFilterSortHelpers.mergedFilterOptions(
            available: state.categories,
            activeFilters: state.filters,
            method: .category
        )
    }

    var body: some View {
        if #available(iOS 16.4, *) {
            navigationContent
                .presentationBackground(Color(uiColor: .systemBackground))
        } else {
            navigationContent
        }
    }

    @ViewBuilder
    private var navigationContent: some View {
        PlatformNavigationStack {
            ZStack {
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()

                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 20) {
                        sortSection
                        filtersSection
                        contentRatingSection

                        if !mergedSourceKeys.isEmpty {
                            collapsibleChipSection(
                                title: LibraryFilter.FilterMethod.source.title,
                                activeCount: activeCount(for: .source),
                                isExpanded: $isSourcesExpanded,
                                items: mergedSourceKeys
                            ) { key in
                                filterChip(
                                    title: resolveSourceName(key),
                                    systemImage: nil,
                                    triState: LibraryFilterSortHelpers.state(
                                        for: .source,
                                        value: key,
                                        in: state.filters
                                    )
                                ) {
                                    onToggleFilter(.source, key)
                                }
                            }
                        }

                        if !mergedCategories.isEmpty {
                            collapsibleChipSection(
                                title: LibraryFilter.FilterMethod.category.title,
                                activeCount: activeCount(for: .category),
                                isExpanded: $isCategoriesExpanded,
                                items: mergedCategories
                            ) { category in
                                filterChip(
                                    title: category,
                                    systemImage: nil,
                                    triState: LibraryFilterSortHelpers.state(
                                        for: .category,
                                        value: category,
                                        in: state.filters
                                    )
                                ) {
                                    onToggleFilter(.category, category)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
            .navigationTitle(ForkL10n.string("LIBRARY_FILTER_SORT_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CloseButton {
                        dismiss()
                    }
                }
            }
        }
    }
}

private extension LibraryFilterSortSheet {
    var sortSection: some View {
        let directionTitle = state.sortAscending
            ? state.sortMethod.ascendingTitle
            : state.sortMethod.descendingTitle
        let isUp = LibraryFilterSortHelpers.isVisuallyAscending(
            method: state.sortMethod,
            sortAscending: state.sortAscending
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(ForkL10n.string("LIBRARY_SORT_TAB"))
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: isUp ? "arrow.up" : "arrow.down")
                        .font(.caption.weight(.semibold))
                    Text(directionTitle)
                        .font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
            }

            chipFlow(items: LibraryViewModel.SortMethod.allCases) { method in
                sortChip(for: method, isUp: isUp)
            }
        }
    }

    var filtersSection: some View {
        let title = state.activeFilterCount > 0
            ? ForkL10n.format("LIBRARY_FILTER_TAB_COUNT_FORMAT", state.activeFilterCount)
            : NSLocalizedString("BUTTON_FILTER")
        let availableMethods = LibraryFilter.FilterMethod.allCases.filter(\.isAvailable)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle(title)
                Spacer()
                if !state.filters.isEmpty {
                    Button(NSLocalizedString("CLEAR"), role: .destructive) {
                        onClearFilters()
                    }
                    .font(.subheadline.weight(.medium))
                }
            }

            if state.isViewingFilterGroup, let groupTitle = state.activeFilterGroupTitle {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.tint)
                    Text(ForkL10n.format("LIBRARY_FILTER_GROUP_ACTIVE_NOTE_FORMAT", groupTitle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            chipFlow(items: availableMethods) { method in
                filterChip(
                    title: method.title,
                    systemImage: methodSystemImage(method),
                    triState: LibraryFilterSortHelpers.state(for: method, in: state.filters)
                ) {
                    onToggleFilter(method, nil)
                }
            }

            Text(ForkL10n.string("LIBRARY_FILTER_TRISTATE_HINT"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var contentRatingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                sectionTitle(LibraryFilter.FilterMethod.contentRating.title)
                countBadge(activeCount(for: .contentRating))
                Spacer()
            }

            chipFlow(items: MangaContentRating.allCases) { rating in
                filterChip(
                    title: rating.title,
                    systemImage: nil,
                    triState: LibraryFilterSortHelpers.state(
                        for: .contentRating,
                        value: rating.stringValue,
                        in: state.filters
                    )
                ) {
                    onToggleFilter(.contentRating, rating.stringValue)
                }
            }
        }
    }

    func collapsibleChipSection<Item: Hashable, ChipContent: View>(
        title: String,
        activeCount: Int,
        isExpanded: Binding<Bool>,
        items: [Item],
        @ViewBuilder chipContent: @escaping (Item) -> ChipContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    sectionTitle(title)
                    countBadge(activeCount)
                    Spacer()
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded.wrappedValue {
                chipFlow(items: items, content: chipContent)
            }
        }
    }

    func sortChip(for method: LibraryViewModel.SortMethod, isUp: Bool) -> some View {
        let isSelected = state.sortMethod == method
        return Button {
            onSelectSort(method)
        } label: {
            HStack(spacing: 5) {
                Text(method.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: isUp ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? Color.clear : Color(uiColor: .separator).opacity(0.35),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }

    func filterChip(
        title: String,
        systemImage: String?,
        triState: LibraryFilterTriState,
        action: @escaping () -> Void
    ) -> some View {
        let backgroundColor: Color = switch triState {
            case .off: Color(uiColor: .secondarySystemBackground)
            case .included: .accentColor
            case .excluded: Color(uiColor: .systemRed)
        }
        let foregroundColor: Color = triState == .off ? .primary : .white
        let leadingIcon: String? = switch triState {
            case .off: systemImage
            case .included: "checkmark"
            case .excluded: "xmark"
        }

        return Button(action: action) {
            HStack(spacing: 6) {
                if let leadingIcon {
                    Image(systemName: leadingIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(triState == .off ? Color.secondary : Color.white)
                }
                Text(title)
                    .font(.subheadline.weight(triState == .off ? .medium : .semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(foregroundColor)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        triState == .off ? Color(uiColor: .separator).opacity(0.35) : Color.clear,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityValue(accessibilityValue(for: triState))
    }

    @ViewBuilder
    func chipFlow<Item: Hashable, ChipContent: View>(
        items: [Item],
        @ViewBuilder content: @escaping (Item) -> ChipContent
    ) -> some View {
        if !items.isEmpty {
            if #available(iOS 16.0, *) {
                FilterChipFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(items, id: \.self) { item in
                        content(item)
                    }
                }
            } else {
                WrappingHStack(items, id: \.self) { item in
                    content(item)
                        .padding([.trailing, .bottom], 8)
                }
            }
        }
    }

    func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
    }

    @ViewBuilder
    func countBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(Capsule())
        }
    }

    func activeCount(for method: LibraryFilter.FilterMethod) -> Int {
        state.filters.filter { $0.type == method }.count
    }

    func methodSystemImage(_ method: LibraryFilter.FilterMethod) -> String {
        if method == .tracking {
            if #available(iOS 18.0, *) {
                return method.systemImageName
            }
            return "arrow.triangle.2.circlepath"
        }
        return method.systemImageName
    }

    func accessibilityValue(for triState: LibraryFilterTriState) -> String {
        switch triState {
            case .off: ForkL10n.string("LIBRARY_FILTER_STATE_OFF")
            case .included: ForkL10n.string("LIBRARY_FILTER_STATE_INCLUDED")
            case .excluded: ForkL10n.string("LIBRARY_FILTER_STATE_EXCLUDED")
        }
    }
}

@available(iOS 16.0, *)
private struct FilterChipFlowLayout: Layout {
    private struct PlacedItem {
        let index: Int
        let origin: CGPoint
        let size: CGSize
    }

    private struct Arrangement {
        let size: CGSize
        let items: [PlacedItem]
    }

    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        arrange(maxWidth: proposal.width, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let arrangement = arrange(maxWidth: bounds.width, subviews: subviews)
        for item in arrangement.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func arrange(maxWidth: CGFloat?, subviews: Subviews) -> Arrangement {
        let availableWidth = maxWidth ?? .greatestFiniteMagnitude
        let itemProposal = ProposedViewSize(
            width: availableWidth.isFinite ? availableWidth : nil,
            height: nil
        )
        var items: [PlacedItem] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0

        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(itemProposal)
            if currentX > 0 && currentX + horizontalSpacing + size.width > availableWidth {
                widestRow = max(widestRow, currentX)
                currentX = 0
                currentY += rowHeight + verticalSpacing
                rowHeight = 0
            }
            if currentX > 0 {
                currentX += horizontalSpacing
            }
            items.append(PlacedItem(index: index, origin: CGPoint(x: currentX, y: currentY), size: size))
            currentX += size.width
            rowHeight = max(rowHeight, size.height)
        }

        widestRow = max(widestRow, currentX)
        let totalHeight = items.isEmpty ? 0 : currentY + rowHeight
        let resolvedWidth = maxWidth ?? widestRow
        return Arrangement(size: CGSize(width: resolvedWidth, height: totalHeight), items: items)
    }
}
