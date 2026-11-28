//
//  LibraryFilterSortSheet.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import SwiftUI

struct LibraryFilterSortSheet: View {
    enum Tab: Int, CaseIterable {
        case filter
        case sort
    }

    @ObservedObject var state: LibraryFilterSortState
    let resolveSourceName: (String) -> String
    let onToggleFilter: (LibraryFilter.FilterMethod, String?) -> Void
    let onClearFilters: () -> Void
    let onSelectSort: (LibraryViewModel.SortMethod) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Tab = .filter
    @State private var isContentRatingExpanded: Bool
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

        self._isContentRatingExpanded = State(
            initialValue: state.filters.contains { $0.type == .contentRating }
        )
        self._isSourcesExpanded = State(
            initialValue: state.filters.contains { $0.type == .source }
        )
        self._isCategoriesExpanded = State(
            initialValue: state.filters.contains { $0.type == .category }
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
        PlatformNavigationStack {
            VStack(spacing: 0) {
                Picker(ForkL10n.string("LIBRARY_FILTER_SORT_TITLE"), selection: $selectedTab) {
                    Text(filterTabTitle).tag(Tab.filter)
                    Text(ForkL10n.string("LIBRARY_SORT_TAB")).tag(Tab.sort)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4)
                .padding(.bottom, 8)

                List {
                    switch selectedTab {
                        case .filter:
                            filterSections
                        case .sort:
                            sortSections
                    }
                }
            }
            .navigationTitle(ForkL10n.string("LIBRARY_FILTER_SORT_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !state.filters.isEmpty {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(NSLocalizedString("CLEAR"), role: .destructive) {
                            onClearFilters()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    DoneButton {
                        dismiss()
                    }
                }
            }
        }
    }

    private var filterTabTitle: String {
        if state.activeFilterCount > 0 {
            return ForkL10n.format("LIBRARY_FILTER_TAB_COUNT_FORMAT", state.activeFilterCount)
        }
        return NSLocalizedString("BUTTON_FILTER")
    }
}

private extension LibraryFilterSortSheet {
    @ViewBuilder
    var filterSections: some View {
        if state.isViewingFilterGroup, let groupTitle = state.activeFilterGroupTitle {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(.tint)
                    Text(ForkL10n.format("LIBRARY_FILTER_GROUP_ACTIVE_NOTE_FORMAT", groupTitle))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }

        Section {
            ForEach(LibraryFilter.FilterMethod.allCases.filter(\.isAvailable), id: \.self) { method in
                filterRow(
                    title: method.title,
                    systemImage: method.systemImageName,
                    triState: LibraryFilterSortHelpers.state(for: method, in: state.filters)
                ) {
                    onToggleFilter(method, nil)
                }
            }
        }

        Section {
            DisclosureGroup(isExpanded: $isContentRatingExpanded) {
                ForEach(MangaContentRating.allCases, id: \.self) { rating in
                    filterRow(
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
            } label: {
                disclosureHeader(for: .contentRating)
            }

            if !mergedSourceKeys.isEmpty {
                DisclosureGroup(isExpanded: $isSourcesExpanded) {
                    ForEach(mergedSourceKeys, id: \.self) { key in
                        filterRow(
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
                } label: {
                    disclosureHeader(for: .source)
                }
            }

            if !mergedCategories.isEmpty {
                DisclosureGroup(isExpanded: $isCategoriesExpanded) {
                    ForEach(mergedCategories, id: \.self) { category in
                        filterRow(
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
                } label: {
                    disclosureHeader(for: .category)
                }
            }
        } footer: {
            Text(ForkL10n.string("LIBRARY_FILTER_TRISTATE_HINT"))
        }
    }

    var sortSections: some View {
        Section {
            ForEach(LibraryViewModel.SortMethod.allCases, id: \.self) { method in
                let isSelected = state.sortMethod == method
                let directionTitle = state.sortAscending ? method.ascendingTitle : method.descendingTitle
                let isUp = LibraryFilterSortHelpers.isVisuallyAscending(
                    method: method,
                    sortAscending: state.sortAscending
                )

                Button {
                    onSelectSort(method)
                } label: {
                    HStack(spacing: 12) {
                        Text(method.title)
                            .foregroundStyle(.primary)

                        Spacer()

                        if isSelected {
                            HStack(spacing: 4) {
                                Text(directionTitle)
                                    .font(.caption.weight(.medium))
                                Image(systemName: isUp ? "arrow.up" : "arrow.down")
                                    .font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.14))
                            .clipShape(Capsule())
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        } footer: {
            Text(ForkL10n.string("LIBRARY_SORT_TAP_HINT"))
        }
    }

    func disclosureHeader(for method: LibraryFilter.FilterMethod) -> some View {
        let count = state.filters.filter { $0.type == method }.count
        return HStack(spacing: 12) {
            Image(systemName: method.systemImageName)
                .frame(width: 24)
                .foregroundStyle(.tint)
            Text(method.title)
                .foregroundStyle(.primary)
            Spacer()
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
    }

    func filterRow(
        title: String,
        systemImage: String?,
        triState: LibraryFilterTriState,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .frame(width: 24)
                        .foregroundStyle(.tint)
                }

                Text(title)
                    .foregroundStyle(.primary)

                Spacer()

                triStateIndicator(for: triState)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(accessibilityValue(for: triState))
    }

    @ViewBuilder
    func triStateIndicator(for triState: LibraryFilterTriState) -> some View {
        switch triState {
            case .off:
                Image(systemName: "circle")
                    .font(.body)
                    .foregroundStyle(Color(uiColor: .tertiaryLabel))
            case .included:
                Image(systemName: "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
            case .excluded:
                Image(systemName: "xmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.red)
        }
    }

    func accessibilityValue(for triState: LibraryFilterTriState) -> String {
        switch triState {
            case .off: ForkL10n.string("LIBRARY_FILTER_STATE_OFF")
            case .included: ForkL10n.string("LIBRARY_FILTER_STATE_INCLUDED")
            case .excluded: ForkL10n.string("LIBRARY_FILTER_STATE_EXCLUDED")
        }
    }
}
