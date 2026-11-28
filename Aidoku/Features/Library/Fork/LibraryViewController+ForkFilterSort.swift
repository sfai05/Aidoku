//
//  LibraryViewController+ForkFilterSort.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import SwiftUI
import UIKit

@MainActor
final class LibraryFilterSortCoordinator {
    weak var activeSheetState: LibraryFilterSortState?
    var isShowingActiveFiltersHeader = false
    var lastTopHeaderHeight: CGFloat = 0
    var isLoadingResults = false
    var reloadGeneration = 0
    var activeReloadTask: Task<Void, Never>?
    var pendingLibraryLoad = false
    var pendingSortOnly = false
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

        filterSortBarButton.isEnabled = !locked
        filterSortBarButton.accessibilityLabel = ForkL10n.string("LIBRARY_FILTER_SORT_TITLE")
        filterSortBarButton.accessibilityValue = hasActiveFilters
            ? ForkL10n.format("LIBRARY_ACTIVE_FILTERS_COUNT_FORMAT", viewModel.filters.count)
            : nil
    }

    func refreshActiveFiltersHeader(animatedCategoryScroll: Bool = false) {
        let showCategories = shouldShowCategoryBar
        let shouldShow = shouldShowActiveFiltersBar
        let expectedHeight = LibraryTopHeaderView.totalHeight(
            showCategories: showCategories,
            showActiveFilters: shouldShow
        )
        if shouldShow != forkFilterSortCoordinator.isShowingActiveFiltersHeader
            || expectedHeight != forkFilterSortCoordinator.lastTopHeaderHeight {
            collectionView.collectionViewLayout = makeCollectionViewLayout()
        }
        for case let header as LibraryTopHeaderView in collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            header.configureVisibility(showCategories: showCategories, showActiveFilters: shouldShow)
            if showCategories {
                header.categoryBarView.delegate = self
                header.categoryBarView.configure(
                    with: buildCategoryBarSnapshot(),
                    animatedScroll: animatedCategoryScroll
                )
            }
            if shouldShow {
                configureActiveFiltersHeader(header.activeFiltersView)
            }
        }
    }

    func syncFilterSortUIState(animatedCategoryScroll: Bool = false) {
        forkFilterSortCoordinator.activeSheetState?.update(
            from: viewModel,
            isUpdatingResults: forkFilterSortCoordinator.isLoadingResults
        )
        updateFilterSortBarButton()
        refreshActiveFiltersHeader(animatedCategoryScroll: animatedCategoryScroll)
    }

    static func makeFilterSortSheetDetents() -> [UISheetPresentationController.Detent] {
        if #available(iOS 16.0, *) {
            let preferred = UISheetPresentationController.Detent.custom(
                identifier: .init("libraryFilterSortPreferred")
            ) { context in
                LibraryFilterSortHelpers.preferredSheetDetentHeight(
                    maximumDetentValue: context.maximumDetentValue
                )
            }
            return [preferred, .large()]
        }
        return [.medium(), .large()]
    }

    private func configureFilterSortSheetPresentation(_ sheet: UISheetPresentationController) {
        sheet.detents = Self.makeFilterSortSheetDetents()
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
    }

    func configureFilterSortPresentation(
        for controller: UIViewController,
        horizontalSizeClass: UIUserInterfaceSizeClass,
        userInterfaceIdiom: UIUserInterfaceIdiom
    ) {
        let usePopover = LibraryFilterSortHelpers.shouldPresentAsPopover(
            isPad: userInterfaceIdiom == .pad,
            isRegularWidth: horizontalSizeClass == .regular
        )
        let canAnchorToBarButton = navigationController != nil
            && navigationItem.rightBarButtonItems?.contains(filterSortBarButton) == true

        if usePopover && canAnchorToBarButton {
            controller.modalPresentationStyle = .popover
            if let popover = controller.popoverPresentationController {
                controller.preferredContentSize = LibraryFilterSortHelpers.preferredPopoverContentSize
                if #available(iOS 16.0, *) {
                    popover.sourceItem = filterSortBarButton
                } else {
                    popover.barButtonItem = filterSortBarButton
                }
                popover.permittedArrowDirections = .any
                popover.passthroughViews = []
                configureFilterSortSheetPresentation(popover.adaptiveSheetPresentationController)
                return
            }
        }

        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController {
            configureFilterSortSheetPresentation(sheet)
        }
    }

    @objc func openFilterSortSheet() {
        guard !locked, presentedViewController == nil else { return }
        let state = LibraryFilterSortState(
            viewModel: viewModel,
            isUpdatingResults: forkFilterSortCoordinator.isLoadingResults
        )
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
        controller.view.backgroundColor = .systemGroupedBackground
        configureFilterSortPresentation(
            for: controller,
            horizontalSizeClass: traitCollection.horizontalSizeClass,
            userInterfaceIdiom: traitCollection.userInterfaceIdiom
        )
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
        triggerCoalescedReload(requiresFullLoad: false)
    }

    private func triggerCoalescedReload(requiresFullLoad: Bool) {
        forkFilterSortCoordinator.reloadGeneration &+= 1
        if requiresFullLoad {
            forkFilterSortCoordinator.pendingLibraryLoad = true
            forkFilterSortCoordinator.isLoadingResults = true
        } else {
            forkFilterSortCoordinator.pendingSortOnly = true
        }
        syncFilterSortUIState()

        guard forkFilterSortCoordinator.activeReloadTask == nil else {
            return
        }

        forkFilterSortCoordinator.activeReloadTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let runFullLoad = self.forkFilterSortCoordinator.pendingLibraryLoad
                let runSort = self.forkFilterSortCoordinator.pendingSortOnly
                guard runFullLoad || runSort else { break }

                let generationAtStart = self.forkFilterSortCoordinator.reloadGeneration
                self.forkFilterSortCoordinator.pendingLibraryLoad = false
                self.forkFilterSortCoordinator.pendingSortOnly = false

                if runFullLoad {
                    await self.viewModel.loadLibrary()
                } else {
                    await self.viewModel.sortLibrary()
                }

                if self.forkFilterSortCoordinator.reloadGeneration == generationAtStart {
                    self.forkFilterSortCoordinator.isLoadingResults = false
                    self.updateEmptyStack()
                    self.updateDataSource()
                    self.syncFilterSortUIState()
                }
            }
            guard let self else { return }
            self.forkFilterSortCoordinator.activeReloadTask = nil
            if self.forkFilterSortCoordinator.isLoadingResults {
                self.forkFilterSortCoordinator.isLoadingResults = false
                self.forkFilterSortCoordinator.activeSheetState?.update(
                    from: self.viewModel,
                    isUpdatingResults: false
                )
            }
        }
    }
}
