//
//  LibraryViewController+ForkFilterSort.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import SwiftUI
import UIKit

@MainActor
final class LibraryFilterSortCoordinator {
    weak var activeSheetState: LibraryFilterSortState?
    var isShowingActiveFiltersHeader = false
    var reloadGeneration = 0
    var activeReloadTask: Task<Void, Never>?
    var pendingLibraryLoad = false
}

// MARK: - Fork: Dedicated Filter & Sort sheet and active filter chips
extension LibraryViewController {
    func resolveSourceName(for key: String) -> String {
        SourceManager.shared.store.source(for: key)?.name ?? key
    }

    func buildActiveFilterChips() -> [LibraryActiveFilterChip] {
        LibraryFilterSortHelpers.activeFilterChips(
            for: viewModel.filters,
            resolveSourceName: resolveSourceName(for:)
        )
    }

    func makeActiveFiltersRegistration() -> UICollectionView.SupplementaryRegistration<LibraryActiveFiltersHeaderView> {
        UICollectionView.SupplementaryRegistration<LibraryActiveFiltersHeaderView>(
            elementKind: LibraryActiveFiltersHeaderView.elementKind
        ) { [weak self] header, _, _ in
            guard let self else { return }
            self.configureActiveFiltersHeader(header)
        }
    }

    func configureActiveFiltersHeader(_ header: LibraryActiveFiltersHeaderView) {
        header.configure(
            chips: buildActiveFilterChips(),
            onRemoveFilter: { [weak self] filter in
                self?.removeFilter(method: filter.type, value: filter.value)
            },
            onClearAll: { [weak self] in
                self?.clearAllFilters()
            }
        )
    }

    func updateFilterSortBarButton() {
        let hasActiveFilters = !viewModel.filters.isEmpty
        if #available(iOS 26.0, *) {
            filterSortBarButton.isSelected = hasActiveFilters
            filterSortBarButton.image = hasActiveFilters
                ? UIImage(systemName: "line.3.horizontal.decrease")?
                    .withTintColor(.white, renderingMode: .alwaysOriginal)
                : UIImage(systemName: "line.3.horizontal.decrease")
        } else {
            filterSortBarButton.image = UIImage(
                systemName: hasActiveFilters
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease"
            )
            filterSortBarButton.tintColor = hasActiveFilters ? view.tintColor : nil
        }

        filterSortBarButton.accessibilityLabel = ForkL10n.string("LIBRARY_FILTER_SORT_TITLE")
        filterSortBarButton.accessibilityValue = hasActiveFilters
            ? ForkL10n.format("LIBRARY_ACTIVE_FILTERS_COUNT_FORMAT", viewModel.filters.count)
            : nil
    }

    func refreshActiveFiltersHeader() {
        let shouldShow = !viewModel.filters.isEmpty && !locked
        if shouldShow != forkFilterSortCoordinator.isShowingActiveFiltersHeader {
            collectionView.collectionViewLayout = makeCollectionViewLayout()
        }
        if
            shouldShow,
            let header = collectionView.supplementaryView(
                forElementKind: LibraryActiveFiltersHeaderView.elementKind,
                at: IndexPath(index: 0)
            ) as? LibraryActiveFiltersHeaderView
        {
            configureActiveFiltersHeader(header)
        }
    }

    func syncFilterSortUIState() {
        forkFilterSortCoordinator.activeSheetState?.update(from: viewModel)
        updateFilterSortBarButton()
        refreshActiveFiltersHeader()
    }

    @objc func openFilterSortSheet() {
        let state = LibraryFilterSortState(viewModel: viewModel)
        forkFilterSortCoordinator.activeSheetState = state

        let sheetView = LibraryFilterSortSheet(
            state: state,
            resolveSourceName: { [weak self] key in
                self?.resolveSourceName(for: key) ?? key
            },
            onToggleFilter: { [weak self] method, value in
                self?.toggleFilterFromSheet(method: method, value: value)
            },
            onClearFilters: { [weak self] in
                self?.clearAllFilters()
            },
            onSelectSort: { [weak self] method in
                self?.selectSortFromSheet(method: method)
            }
        )

        let controller = UIHostingController(rootView: sheetView)
        if let sheet = controller.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        present(controller, animated: true)
    }

    @objc func clearFiltersFromEmptyState() {
        clearAllFilters()
    }

    func toggleFilterFromSheet(method: LibraryFilter.FilterMethod, value: String? = nil) {
        viewModel.applyFilterToggleMutation(method: method, value: value)
        triggerCoalescedReload(requiresFullLoad: true)
    }

    func removeFilter(method: LibraryFilter.FilterMethod, value: String? = nil) {
        viewModel.applyFilterRemovalMutation(method: method, value: value)
        triggerCoalescedReload(requiresFullLoad: true)
    }

    func clearAllFilters() {
        guard !viewModel.filters.isEmpty else { return }
        viewModel.clearAllFiltersMutation()
        triggerCoalescedReload(requiresFullLoad: true)
    }

    func selectSortFromSheet(method: LibraryViewModel.SortMethod) {
        let next = LibraryFilterSortHelpers.nextSort(
            currentMethod: viewModel.sortMethod,
            currentAscending: viewModel.sortAscending,
            tappedMethod: method
        )
        guard viewModel.applySortMutation(method: next.method, ascending: next.ascending) else {
            return
        }
        triggerCoalescedReload(requiresFullLoad: forkFilterSortCoordinator.pendingLibraryLoad)
    }

    private func triggerCoalescedReload(requiresFullLoad: Bool) {
        if requiresFullLoad {
            forkFilterSortCoordinator.pendingLibraryLoad = true
        }
        syncFilterSortUIState()

        forkFilterSortCoordinator.activeReloadTask?.cancel()
        forkFilterSortCoordinator.reloadGeneration &+= 1
        let expectedGeneration = forkFilterSortCoordinator.reloadGeneration
        let runFullLoad = forkFilterSortCoordinator.pendingLibraryLoad

        forkFilterSortCoordinator.activeReloadTask = Task { [weak self] in
            guard let self else { return }
            if runFullLoad {
                await self.viewModel.loadLibrary()
            } else {
                await self.viewModel.sortLibrary()
            }
            guard !Task.isCancelled, self.forkFilterSortCoordinator.reloadGeneration == expectedGeneration else {
                return
            }
            if runFullLoad {
                self.forkFilterSortCoordinator.pendingLibraryLoad = false
            }
            self.updateEmptyStack()
            self.updateDataSource()
            self.syncFilterSortUIState()
        }
    }
}
