//
//  MangaBakaCoverPickerSheet.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import SwiftUI

enum CoverGalleryTypeFilter: String, CaseIterable, Hashable, Identifiable {
    case volumes
    case all

    var id: Self { self }

    var apiValue: String? {
        switch self {
            case .volumes: "volume"
            case .all: nil
        }
    }

    var title: String {
        switch self {
            case .volumes: ForkL10n.string("METADATA_COVERS_FILTER_VOLUMES")
            case .all: ForkL10n.string("METADATA_COVERS_FILTER_ALL")
        }
    }
}

@MainActor
final class MangaBakaCoverPickerViewModel: ObservableObject {
    private struct CacheKey: Hashable {
        let typeFilter: CoverGalleryTypeFilter
        let languageCode: String?
    }

    private struct CachedPage {
        var covers: [TrackerCoverOption]
        var totalCount: Int
        var hasNextPage: Bool
        var currentPage: Int
    }

    let selectedCoverUrl: String?
    @Published private(set) var selectedTypeFilter: CoverGalleryTypeFilter = .volumes
    @Published private(set) var selectedLanguageFilter: String?
    @Published private(set) var covers: [TrackerCoverOption]
    @Published private(set) var totalCount: Int
    @Published private(set) var hasNextPage: Bool
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var loadMoreErrorMessage: String?

    private let trackId: String
    private let mainCoverUrl: String?
    private let metadataProvider: TrackerMetadataProvider
    private let priorityOrder: [String]
    private let hasLoadedInitialCovers: Bool
    private var hasAttemptedInitialLoad: Bool
    private var rawAvailableLanguages: [String] = []
    private var cache: [CacheKey: CachedPage] = [:]
    private var currentPage = 1
    private var requestGeneration = 0
    private var activePageTask: Task<Void, Never>?
    private var activeLoadMoreTask: Task<Void, Never>?
    private var pageTaskToken = UUID()
    private var loadMoreTaskToken = UUID()

    init(
        metadata: TrackerMangaMetadata,
        selectedCoverUrl: String?,
        metadataProvider: TrackerMetadataProvider,
        priorityOrder: [String]
    ) {
        self.trackId = metadata.trackId
        self.mainCoverUrl = metadata.coverUrl.flatMap {
            MangaMetadataService.isValidRemoteCoverURL($0) ? $0 : nil
        }
        self.selectedCoverUrl = selectedCoverUrl
        self.metadataProvider = metadataProvider
        self.priorityOrder = priorityOrder
        self.hasLoadedInitialCovers = metadata.hasLoadedInitialCovers
        self.hasAttemptedInitialLoad = metadata.hasLoadedInitialCovers

        let nonMainInitial = metadata.coverOptions.filter { !$0.isMain }
        let initialType: CoverGalleryTypeFilter
        if let filterType = metadata.initialCoverFilterType {
            initialType = filterType.caseInsensitiveCompare("volume") == .orderedSame ? .volumes : .all
        } else if metadata.hasLoadedInitialCovers {
            if nonMainInitial.contains(where: { $0.type.caseInsensitiveCompare("volume") != .orderedSame }) {
                initialType = .all
            } else if !nonMainInitial.isEmpty {
                initialType = .volumes
            } else {
                initialType = .all
            }
        } else {
            initialType = .volumes
        }

        self.selectedTypeFilter = initialType
        self.covers = metadata.coverOptions
        self.totalCount = max(metadata.totalCoverCount, metadata.coverOptions.count)
        self.hasNextPage = metadata.hasMoreCovers
        self.mergeAvailableLanguages(metadata.availableCoverLanguages)

        if metadata.hasLoadedInitialCovers {
            self.cache[CacheKey(typeFilter: initialType, languageCode: nil)] = CachedPage(
                covers: metadata.coverOptions,
                totalCount: self.totalCount,
                hasNextPage: metadata.hasMoreCovers,
                currentPage: 1
            )
        }
    }

    var availableLanguages: [String] {
        var candidates: [String] = []
        var seenLower: Set<String> = []

        for raw in rawAvailableLanguages {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("unknown") != .orderedSame else {
                continue
            }
            if seenLower.insert(trimmed.lowercased()).inserted {
                candidates.append(trimmed)
            }
        }

        if candidates.isEmpty {
            for cached in cache.values {
                for cover in cached.covers {
                    let trimmed = cover.languageCode.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("unknown") != .orderedSame else {
                        continue
                    }
                    if seenLower.insert(trimmed.lowercased()).inserted {
                        candidates.append(trimmed)
                    }
                }
            }
        }

        guard !candidates.isEmpty else { return [] }

        var groupedByNormalized: [String: [String]] = [:]
        for raw in candidates {
            let normKey = TitleLanguagePriorityStore.normalizeRegionLanguageCode(raw).lowercased()
            groupedByNormalized[normKey, default: []].append(raw)
        }

        var ordered: [String] = []
        var seenNormKeys: Set<String> = []

        for code in priorityOrder {
            let normKey = TitleLanguagePriorityStore.normalizeRegionLanguageCode(code).lowercased()
            guard seenNormKeys.insert(normKey).inserted, let group = groupedByNormalized[normKey] else {
                continue
            }
            ordered.append(contentsOf: sortRawLanguageVariants(group, normalizedKey: normKey))
        }

        let fallbackOrder = ["ja", "en", "zh-hant", "zh-hans", "zh", "ko"]
        let remainingNormKeys = groupedByNormalized.keys
            .filter { !seenNormKeys.contains($0) }
            .sorted { lhs, rhs in
                let lIdx = fallbackOrder.firstIndex(of: lhs) ?? fallbackOrder.count
                let rIdx = fallbackOrder.firstIndex(of: rhs) ?? fallbackOrder.count
                if lIdx != rIdx { return lIdx < rIdx }
                return lhs < rhs
            }
        for normKey in remainingNormKeys {
            if let group = groupedByNormalized[normKey] {
                ordered.append(contentsOf: sortRawLanguageVariants(group, normalizedKey: normKey))
            }
        }
        return ordered
    }

    func languageChipTitle(for rawCode: String) -> String {
        let normalized = TitleLanguagePriorityStore.normalizeRegionLanguageCode(rawCode)
        let base = TitleLanguagePriorityStore.shortLabel(for: normalized)

        let collisionCount = availableLanguages.filter { candidate in
            let candNormalized = TitleLanguagePriorityStore.normalizeRegionLanguageCode(candidate)
            return TitleLanguagePriorityStore.shortLabel(for: candNormalized) == base
        }.count

        guard collisionCount > 1 else {
            return base
        }

        if rawCode.caseInsensitiveCompare(normalized) == .orderedSame {
            return base
        }

        let parts = rawCode
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
        if parts.count >= 2, let last = parts.last, last.count == 2 {
            return "\(base) (\(last.uppercased()))"
        }
        return rawCode.uppercased()
    }

    func loadInitialIfNeeded() async {
        guard !hasLoadedInitialCovers && !hasAttemptedInitialLoad else { return }
        hasAttemptedInitialLoad = true
        requestGeneration += 1
        let generation = requestGeneration
        isLoading = true
        isLoadingMore = false
        errorMessage = nil
        loadMoreErrorMessage = nil
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }

        do {
            let volumePage = try await metadataProvider.fetchCoverPage(
                trackId: trackId,
                page: 1,
                type: CoverGalleryTypeFilter.volumes.apiValue,
                language: nil
            )
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }

            let finalPage: TrackerCoverPage
            let usedType: String?
            if !volumePage.covers.isEmpty || volumePage.totalCount > 0 {
                finalPage = volumePage
                usedType = volumePage.requestedType ?? CoverGalleryTypeFilter.volumes.apiValue
            } else {
                let allPage = try await metadataProvider.fetchCoverPage(
                    trackId: trackId,
                    page: 1,
                    type: nil,
                    language: nil
                )
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                finalPage = allPage
                usedType = allPage.requestedType
            }

            let resolvedFilter: CoverGalleryTypeFilter = usedType?.caseInsensitiveCompare("volume") == .orderedSame
                ? .volumes
                : .all
            applyFirstPage(finalPage, typeFilter: resolvedFilter, languageFilter: nil)
        } catch is CancellationError {
            if generation == requestGeneration && Task.isCancelled {
                hasAttemptedInitialLoad = false
            }
        } catch {
            guard generation == requestGeneration else { return }
            covers = []
            hasNextPage = false
            totalCount = 0
            errorMessage = error.localizedDescription
        }
    }

    func selectTypeFilter(_ filter: CoverGalleryTypeFilter) async {
        guard !Task.isCancelled, filter != selectedTypeFilter else { return }
        hasAttemptedInitialLoad = true
        selectedTypeFilter = filter
        await loadCurrentFilterPage1()
    }

    func selectLanguageFilter(_ language: String?) async {
        guard !Task.isCancelled, language != selectedLanguageFilter else { return }
        hasAttemptedInitialLoad = true
        selectedLanguageFilter = language
        await loadCurrentFilterPage1()
    }

    func retryCurrentFilter() async {
        guard !Task.isCancelled else { return }
        let key = CacheKey(typeFilter: selectedTypeFilter, languageCode: selectedLanguageFilter)
        cache.removeValue(forKey: key)
        if !hasLoadedInitialCovers && cache.isEmpty && selectedLanguageFilter == nil && selectedTypeFilter == .volumes {
            hasAttemptedInitialLoad = false
            await loadInitialIfNeeded()
        } else {
            await loadCurrentFilterPage1(bypassCache: true)
        }
    }

    func loadMoreIfNeeded(currentItem: TrackerCoverOption) async {
        guard
            !Task.isCancelled,
            hasNextPage,
            !isLoading,
            !isLoadingMore,
            loadMoreErrorMessage == nil,
            let index = covers.firstIndex(where: { $0.id == currentItem.id }),
            index >= max(covers.count - 8, 0)
        else {
            return
        }

        await performLoadMore()
    }

    func retryLoadMore() async {
        guard !Task.isCancelled, hasNextPage, !isLoading, !isLoadingMore else { return }
        await performLoadMore()
    }

    func requestTypeFilter(_ filter: CoverGalleryTypeFilter) {
        startPageTask { viewModel in
            await viewModel.selectTypeFilter(filter)
        }
    }

    func requestLanguageFilter(_ language: String?) {
        startPageTask { viewModel in
            await viewModel.selectLanguageFilter(language)
        }
    }

    func requestRetry() {
        startPageTask { viewModel in
            await viewModel.retryCurrentFilter()
        }
    }

    func requestLoadMoreIfNeeded(currentItem: TrackerCoverOption) {
        guard activeLoadMoreTask == nil else { return }
        startLoadMoreTask { viewModel in
            await viewModel.loadMoreIfNeeded(currentItem: currentItem)
        }
    }

    func requestRetryLoadMore() {
        startLoadMoreTask { viewModel in
            await viewModel.retryLoadMore()
        }
    }

    func cancelPendingRequests() {
        pageTaskToken = UUID()
        activePageTask?.cancel()
        activePageTask = nil
        loadMoreTaskToken = UUID()
        activeLoadMoreTask?.cancel()
        activeLoadMoreTask = nil
    }

    private func startPageTask(_ work: @escaping @MainActor (MangaBakaCoverPickerViewModel) async -> Void) {
        activePageTask?.cancel()
        loadMoreTaskToken = UUID()
        activeLoadMoreTask?.cancel()
        activeLoadMoreTask = nil

        let token = UUID()
        pageTaskToken = token
        activePageTask = Task { [weak self] in
            defer {
                if self?.pageTaskToken == token {
                    self?.activePageTask = nil
                }
            }
            guard let self else { return }
            await work(self)
        }
    }

    private func startLoadMoreTask(_ work: @escaping @MainActor (MangaBakaCoverPickerViewModel) async -> Void) {
        activeLoadMoreTask?.cancel()
        let token = UUID()
        loadMoreTaskToken = token
        activeLoadMoreTask = Task { [weak self] in
            defer {
                if self?.loadMoreTaskToken == token {
                    self?.activeLoadMoreTask = nil
                }
            }
            guard let self else { return }
            await work(self)
        }
    }

    private func performLoadMore() async {
        isLoadingMore = true
        loadMoreErrorMessage = nil
        let generation = requestGeneration
        let key = CacheKey(typeFilter: selectedTypeFilter, languageCode: selectedLanguageFilter)
        let targetPage = currentPage + 1
        defer {
            if generation == requestGeneration {
                isLoadingMore = false
            }
        }

        do {
            let page = try await metadataProvider.fetchCoverPage(
                trackId: trackId,
                page: targetPage,
                type: selectedTypeFilter.apiValue,
                language: selectedLanguageFilter
            )
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }

            mergeAvailableLanguages(page.availableLanguages)

            var merged = covers
            var seenUrls = Set(merged.map(\.rawUrl))
            for item in page.covers where seenUrls.insert(item.rawUrl).inserted {
                merged.append(item)
            }

            covers = merged
            currentPage = targetPage
            hasNextPage = page.hasNextPage
            totalCount = max(merged.count, page.totalCount)
            cache[key] = CachedPage(
                covers: merged,
                totalCount: totalCount,
                hasNextPage: hasNextPage,
                currentPage: currentPage
            )
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            loadMoreErrorMessage = error.localizedDescription
        }
    }

    private func loadCurrentFilterPage1(bypassCache: Bool = false) async {
        requestGeneration += 1
        let generation = requestGeneration
        let typeFilter = selectedTypeFilter
        let languageFilter = selectedLanguageFilter
        let key = CacheKey(typeFilter: typeFilter, languageCode: languageFilter)
        errorMessage = nil
        loadMoreErrorMessage = nil

        if !bypassCache, let cached = cache[key] {
            covers = cached.covers
            totalCount = cached.totalCount
            hasNextPage = cached.hasNextPage
            currentPage = cached.currentPage
            isLoading = false
            isLoadingMore = false
            return
        }

        isLoading = true
        isLoadingMore = false
        defer {
            if generation == requestGeneration {
                isLoading = false
            }
        }

        do {
            let page = try await metadataProvider.fetchCoverPage(
                trackId: trackId,
                page: 1,
                type: typeFilter.apiValue,
                language: languageFilter
            )
            try Task.checkCancellation()
            guard generation == requestGeneration else { return }

            applyFirstPage(page, typeFilter: typeFilter, languageFilter: languageFilter)
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            covers = []
            hasNextPage = false
            totalCount = 0
            errorMessage = error.localizedDescription
        }
    }

    private func applyFirstPage(
        _ page: TrackerCoverPage,
        typeFilter: CoverGalleryTypeFilter,
        languageFilter: String?
    ) {
        mergeAvailableLanguages(page.availableLanguages)

        let key = CacheKey(typeFilter: typeFilter, languageCode: languageFilter)
        let combined = buildFirstPageCovers(
            from: page.covers,
            typeFilter: typeFilter,
            languageFilter: languageFilter
        )
        let includesMain = shouldIncludeMainCover(
            typeFilter: typeFilter,
            languageFilter: languageFilter,
            fetched: page.covers
        )
        let mainInPage = mainCoverUrl != nil && page.covers.contains { $0.rawUrl == mainCoverUrl }
        let resolvedTotal = page.hasNextPage
            ? max(combined.count, page.totalCount + ((includesMain && !mainInPage) ? 1 : 0))
            : combined.count

        selectedTypeFilter = typeFilter
        covers = combined
        currentPage = 1
        hasNextPage = page.hasNextPage
        totalCount = resolvedTotal
        cache[key] = CachedPage(
            covers: combined,
            totalCount: resolvedTotal,
            hasNextPage: page.hasNextPage,
            currentPage: 1
        )
    }

    private func mergeAvailableLanguages(_ incoming: [String]) {
        var seenLower = Set(rawAvailableLanguages.map { $0.lowercased() })
        for raw in incoming {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare("unknown") != .orderedSame else {
                continue
            }
            if seenLower.insert(trimmed.lowercased()).inserted {
                rawAvailableLanguages.append(trimmed)
            }
        }
    }

    private func sortRawLanguageVariants(_ group: [String], normalizedKey: String) -> [String] {
        group.sorted { lhs, rhs in
            let lhsExact = lhs.lowercased() == normalizedKey
            let rhsExact = rhs.lowercased() == normalizedKey
            if lhsExact != rhsExact {
                return lhsExact
            }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private func shouldIncludeMainCover(
        typeFilter: CoverGalleryTypeFilter,
        languageFilter: String?,
        fetched: [TrackerCoverOption]
    ) -> Bool {
        languageFilter == nil && mainCoverUrl != nil && (typeFilter == .all || !fetched.isEmpty)
    }

    private func buildFirstPageCovers(
        from fetched: [TrackerCoverOption],
        typeFilter: CoverGalleryTypeFilter,
        languageFilter: String?
    ) -> [TrackerCoverOption] {
        var result: [TrackerCoverOption] = []
        var seenUrls: Set<String> = []

        if shouldIncludeMainCover(typeFilter: typeFilter, languageFilter: languageFilter, fetched: fetched),
           let mainCoverUrl {
            result.append(
                TrackerCoverOption(
                    id: "main",
                    rawUrl: mainCoverUrl,
                    thumbnailUrl: mainCoverUrl,
                    volumeLabel: nil,
                    type: "main",
                    languageCode: "unknown",
                    isMain: true
                )
            )
            seenUrls.insert(mainCoverUrl)
        }

        for cover in fetched where seenUrls.insert(cover.rawUrl).inserted {
            result.append(cover)
        }
        return result
    }
}

struct MangaBakaCoverPickerSheet: View {
    @StateObject private var viewModel: MangaBakaCoverPickerViewModel
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 3
    )

    init(
        metadata: TrackerMangaMetadata,
        selectedCoverUrl: String?,
        metadataProvider: TrackerMetadataProvider,
        priorityOrder: [String],
        onSelect: @escaping (String) -> Void
    ) {
        self._viewModel = StateObject(
            wrappedValue: MangaBakaCoverPickerViewModel(
                metadata: metadata,
                selectedCoverUrl: selectedCoverUrl,
                metadataProvider: metadataProvider,
                priorityOrder: priorityOrder
            )
        )
        self.onSelect = onSelect
    }

    var body: some View {
        PlatformNavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider()
                galleryContent
            }
            .navigationTitle(ForkL10n.string("METADATA_COVERS_PICKER_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ForkL10n.string("METADATA_CANCEL")) {
                        dismiss()
                    }
                }
            }
            .task {
                await viewModel.loadInitialIfNeeded()
            }
            .onDisappear {
                viewModel.cancelPendingRequests()
            }
        }
    }
}

private extension MangaBakaCoverPickerSheet {
    var filterBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                ForkL10n.string("METADATA_SECTION_COVER"),
                selection: Binding(
                    get: { viewModel.selectedTypeFilter },
                    set: { nextFilter in
                        viewModel.requestTypeFilter(nextFilter)
                    }
                )
            ) {
                ForEach(CoverGalleryTypeFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            let languages = viewModel.availableLanguages
            if !languages.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        languageChip(
                            title: ForkL10n.string("METADATA_COVERS_LANG_ALL"),
                            isSelected: viewModel.selectedLanguageFilter == nil
                        ) {
                            viewModel.requestLanguageFilter(nil)
                        }

                        ForEach(languages, id: \.self) { code in
                            languageChip(
                                title: viewModel.languageChipTitle(for: code),
                                isSelected: viewModel.selectedLanguageFilter == code
                            ) {
                                viewModel.requestLanguageFilter(code)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .padding(.vertical, 10)
        .background(Color(uiColor: .systemGroupedBackground))
    }

    func languageChip(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : Color(uiColor: .secondarySystemFill)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    var galleryContent: some View {
        if viewModel.isLoading {
            VStack(spacing: 12) {
                Spacer()
                ProgressView()
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if let errorMessage = viewModel.errorMessage, viewModel.covers.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button(ForkL10n.string("METADATA_COVERS_RETRY")) {
                    viewModel.requestRetry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else if viewModel.covers.isEmpty {
            VStack(spacing: 10) {
                Spacer()
                Text(ForkL10n.string("METADATA_COVERS_EMPTY"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(viewModel.covers) { cover in
                        coverCell(for: cover)
                            .onAppear {
                                viewModel.requestLoadMoreIfNeeded(currentItem: cover)
                            }
                    }
                }
                .padding()

                if viewModel.isLoadingMore {
                    ProgressView()
                        .padding(.bottom, 16)
                } else if let loadMoreError = viewModel.loadMoreErrorMessage {
                    VStack(spacing: 8) {
                        Text(loadMoreError)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button(ForkL10n.string("METADATA_COVERS_RETRY")) {
                            viewModel.requestRetryLoadMore()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    func coverCell(for cover: TrackerCoverOption) -> some View {
        let isSelected = viewModel.selectedCoverUrl == cover.rawUrl

        return Button {
            onSelect(cover.rawUrl)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Color.clear
                    .aspectRatio(CGFloat(2) / 3, contentMode: .fit)
                    .overlay {
                        GeometryReader { proxy in
                            MangaCoverView(
                                source: nil,
                                coverImage: cover.thumbnailUrl,
                                width: proxy.size.width,
                                height: proxy.size.height,
                                downsampleWidth: 250,
                                contentMode: .fill
                            )
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isSelected ? Color.accentColor : Color.clear,
                                lineWidth: 2.5
                            )
                    )
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(6)
                        }
                    }

                Text(caption(for: cover))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }

    func caption(for cover: TrackerCoverOption) -> String {
        if cover.isMain {
            return ForkL10n.string("METADATA_COVERS_MAIN_LABEL")
        }
        var parts: [String] = []
        if let volumeLabel = cover.volumeLabel, !volumeLabel.isEmpty {
            if cover.type.caseInsensitiveCompare("volume_back") == .orderedSame {
                parts.append(ForkL10n.format("METADATA_COVERS_VOL_BACK_FORMAT", volumeLabel))
            } else {
                parts.append(ForkL10n.format("METADATA_COVERS_VOL_FORMAT", volumeLabel))
            }
        } else if !cover.type.isEmpty {
            parts.append(cover.type.replacingOccurrences(of: "_", with: " ").capitalized)
        }
        if cover.languageCode != "unknown" {
            parts.append(cover.languageCode.uppercased())
        }
        return parts.isEmpty ? ForkL10n.string("METADATA_SECTION_COVER") : parts.joined(separator: " · ")
    }
}
