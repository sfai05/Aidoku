//
//  MangaBakaMetadataPullSheet.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import AidokuRunner
import SwiftUI

struct TrackerMetadataPullDependencies {
    let languagePriorityStore: TitleLanguagePriorityStore
    let metadataProvider: TrackerMetadataProvider

    init(
        languagePriorityStore: TitleLanguagePriorityStore = .shared,
        metadataProvider: TrackerMetadataProvider = MangaBakaMetadataProvider()
    ) {
        self.languagePriorityStore = languagePriorityStore
        self.metadataProvider = metadataProvider
    }
}

struct MangaBakaMetadataPullSheet: View {
    let source: AidokuRunner.Source?
    let currentDraft: MangaMetadataSnapshot
    let metadata: TrackerMangaMetadata
    let dependencies: TrackerMetadataPullDependencies
    let onApply: (TrackerMetadataSelection) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedFields: Set<MetadataEditableField> = []
    @State private var selectedTitleOption: TrackerTitleOption?
    @State private var hasManuallyPickedTitle = false
    @State private var selectedCoverUrl: String?
    @State private var useNativeAuthors: Bool
    @State private var useNativeArtists: Bool
    @State private var selectedDescriptionOption: TrackerDescriptionOption?
    @State private var hasManuallyPickedDescription = false
    @State private var priorityOrder: [String]
    @State private var showingTitlePicker = false
    @State private var showingCoverPicker = false
    @State private var showingDescriptionPicker = false

    init(
        source: AidokuRunner.Source?,
        currentDraft: MangaMetadataSnapshot,
        metadata: TrackerMangaMetadata,
        dependencies: TrackerMetadataPullDependencies = .init(),
        onApply: @escaping (TrackerMetadataSelection) -> Void
    ) {
        self.source = source
        self.currentDraft = currentDraft
        self.metadata = metadata
        self.dependencies = dependencies
        self.onApply = onApply

        let order = dependencies.languagePriorityStore.priorityOrder
        let preferredTitle = TitleLanguagePriorityStore.resolvePreferredTitle(
            from: metadata.titleOptions,
            defaultTitle: metadata.defaultTitle,
            priorityOrder: order
        )
        let preferredDescription = TitleLanguagePriorityStore.resolvePreferredDescription(
            from: metadata.descriptionOptions,
            priorityOrder: order
        )
        let initialNativeAuthors = !metadata.nativeAuthors.isEmpty
        let initialNativeArtists = !metadata.nativeArtists.isEmpty
        let initialAuthors = initialNativeAuthors ? metadata.nativeAuthors : metadata.authors
        let initialArtists = initialNativeArtists ? metadata.nativeArtists : metadata.artists

        let initialCandidates = PullFieldCandidates(
            title: preferredTitle?.title ?? metadata.defaultTitle,
            coverUrl: metadata.coverUrl,
            authors: initialAuthors,
            artists: initialArtists,
            status: metadata.status,
            description: preferredDescription?.text ?? metadata.description,
            tags: metadata.tags
        )

        self._priorityOrder = State(initialValue: order)
        self._selectedTitleOption = State(initialValue: preferredTitle)
        self._selectedCoverUrl = State(initialValue: metadata.coverUrl)
        self._useNativeAuthors = State(initialValue: initialNativeAuthors)
        self._useNativeArtists = State(initialValue: initialNativeArtists)
        self._selectedDescriptionOption = State(initialValue: preferredDescription)
        self._selectedFields = State(
            initialValue: Self.defaultSelectedFields(
                currentDraft: currentDraft,
                candidates: initialCandidates
            )
        )
    }

    private var activePulledTitle: String {
        selectedTitleOption?.title ?? metadata.defaultTitle
    }

    private var activePulledCoverUrl: String? {
        selectedCoverUrl ?? metadata.coverUrl
    }

    private var activePulledAuthors: [String] {
        (useNativeAuthors && !metadata.nativeAuthors.isEmpty) ? metadata.nativeAuthors : metadata.authors
    }

    private var activePulledArtists: [String] {
        (useNativeArtists && !metadata.nativeArtists.isEmpty) ? metadata.nativeArtists : metadata.artists
    }

    private var activePulledDescription: String? {
        selectedDescriptionOption?.text ?? metadata.description
    }

    private var activeCandidates: PullFieldCandidates {
        PullFieldCandidates(
            title: activePulledTitle,
            coverUrl: activePulledCoverUrl,
            authors: activePulledAuthors,
            artists: activePulledArtists,
            status: metadata.status,
            description: activePulledDescription,
            tags: metadata.tags
        )
    }

    private var hasAuthorScriptToggle: Bool {
        !metadata.nativeAuthors.isEmpty && !metadata.authors.isEmpty && metadata.nativeAuthors != metadata.authors
    }

    private var hasArtistScriptToggle: Bool {
        !metadata.nativeArtists.isEmpty && !metadata.artists.isEmpty && metadata.nativeArtists != metadata.artists
    }

    private var totalCoverCount: Int {
        max(metadata.totalCoverCount, metadata.coverOptions.count)
    }

    private var differingFields: [MetadataEditableField] {
        MetadataEditableField.allCases.filter { fieldDiffers($0) }
    }

    private var quickTitleOptions: [TrackerTitleOption] {
        TitleLanguagePriorityStore.quickLanguageOptions(
            from: metadata.titleOptions,
            priorityOrder: priorityOrder,
            limit: 4
        )
    }

    private var quickDescriptionOptions: [TrackerDescriptionOption] {
        TitleLanguagePriorityStore.quickDescriptionOptions(
            from: metadata.descriptionOptions,
            priorityOrder: priorityOrder,
            limit: 4
        )
    }

    var body: some View {
        PlatformNavigationStack {
            List {
                Section {
                    Text(ForkL10n.string("METADATA_PULL_HINT"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(MetadataEditableField.allCases, id: \.self) { field in
                        diffRow(for: field)
                    }
                } header: {
                    HStack {
                        Text(ForkL10n.format("METADATA_PULL_DIFF_COUNT_FORMAT", differingFields.count))
                        Spacer()
                        Button(ForkL10n.string("METADATA_PULL_SELECT_ALL")) {
                            selectedFields = Set(differingFields)
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                        .disabled(differingFields.isEmpty)

                        Button(ForkL10n.string("METADATA_PULL_CLEAR")) {
                            selectedFields.removeAll()
                        }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                        .disabled(selectedFields.isEmpty)
                    }
                }
            }
            .navigationTitle(ForkL10n.string("METADATA_PULL_SHEET_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ForkL10n.string("METADATA_CANCEL")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(ForkL10n.format("METADATA_PULL_APPLY_FORMAT", selectedFields.count)) {
                        onApply(
                            TrackerMetadataSelection(
                                selectedFields: selectedFields,
                                selectedTitle: activePulledTitle,
                                selectedCoverUrl: activePulledCoverUrl,
                                selectedAuthors: activePulledAuthors,
                                selectedArtists: activePulledArtists,
                                selectedDescription: activePulledDescription
                            )
                        )
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .disabled(selectedFields.isEmpty)
                }
            }
            .sheet(isPresented: $showingTitlePicker) {
                TitleVariantPickerSheet(
                    options: sortedTitleOptions(),
                    selectedOption: selectedTitleOption,
                    priorityStore: dependencies.languagePriorityStore,
                    onSelect: { option in
                        selectTitleOption(option)
                    }
                )
            }
            .sheet(isPresented: $showingCoverPicker) {
                MangaBakaCoverPickerSheet(
                    metadata: metadata,
                    selectedCoverUrl: activePulledCoverUrl,
                    metadataProvider: dependencies.metadataProvider,
                    priorityOrder: priorityOrder,
                    onSelect: { chosenUrl in
                        selectedCoverUrl = chosenUrl
                        syncFieldCheckbox(for: .cover)
                    }
                )
            }
            .sheet(isPresented: $showingDescriptionPicker) {
                DescriptionVariantPickerSheet(
                    options: sortedDescriptionOptions(),
                    selectedOption: selectedDescriptionOption,
                    priorityStore: dependencies.languagePriorityStore,
                    onSelect: { option in
                        selectDescriptionOption(option)
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .forkTitleLanguagePriorityChanged)) { _ in
                priorityOrder = dependencies.languagePriorityStore.priorityOrder
                if !hasManuallyPickedTitle {
                    selectedTitleOption = TitleLanguagePriorityStore.resolvePreferredTitle(
                        from: metadata.titleOptions,
                        defaultTitle: metadata.defaultTitle,
                        priorityOrder: priorityOrder
                    )
                    syncFieldCheckbox(for: .title)
                }
                if !hasManuallyPickedDescription {
                    selectedDescriptionOption = TitleLanguagePriorityStore.resolvePreferredDescription(
                        from: metadata.descriptionOptions,
                        priorityOrder: priorityOrder
                    )
                    syncFieldCheckbox(for: .description)
                }
            }
        }
    }
}

private extension MangaBakaMetadataPullSheet {
    func diffRow(for field: MetadataEditableField) -> some View {
        let isSame = !fieldDiffers(field)
        let isChecked = !isSame && selectedFields.contains(field)

        return HStack(alignment: .top, spacing: 12) {
            Button {
                toggleField(field, isSame: isSame)
            } label: {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSame)
            .opacity(isSame ? 0.6 : 1)

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    toggleField(field, isSame: isSame)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        diffHeader(for: field, isSame: isSame)
                        diffContent(for: field, isSame: isSame)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSame)
                .opacity(isSame ? 0.6 : 1)

                fieldAccessoryControls(for: field)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    func toggleField(_ field: MetadataEditableField, isSame: Bool) {
        guard !isSame else { return }
        if selectedFields.contains(field) {
            selectedFields.remove(field)
        } else {
            selectedFields.insert(field)
        }
    }

    @ViewBuilder
    func diffHeader(for field: MetadataEditableField, isSame: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label(for: field))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            headerBadge(for: field)

            Spacer()

            Text(ForkL10n.string(isSame ? "METADATA_PULL_SAME" : "METADATA_PULL_UPDATED"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isSame ? Color.secondary : Color.green)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    (isSame ? Color.secondary : Color.green).opacity(0.15)
                )
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    func headerBadge(for field: MetadataEditableField) -> some View {
        switch field {
            case .title:
                if let code = selectedTitleOption?.languageCode {
                    compactBadge(code)
                }
            case .authors:
                if useNativeAuthors && !metadata.nativeAuthors.isEmpty {
                    compactBadge(ForkL10n.string("METADATA_PERSON_SOURCE_ANILIST"))
                }
            case .artists:
                if useNativeArtists && !metadata.nativeArtists.isEmpty {
                    compactBadge(ForkL10n.string("METADATA_PERSON_SOURCE_ANILIST"))
                }
            case .description:
                if let option = selectedDescriptionOption {
                    compactBadge("\(option.languageCode) · \(option.sourceName)")
                }
            default:
                EmptyView()
        }
    }

    func compactBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(uiColor: .secondarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    @ViewBuilder
    func diffContent(for field: MetadataEditableField, isSame: Bool) -> some View {
        switch field {
            case .title:
                textDiffBody(
                    current: currentDraft.title,
                    incoming: activePulledTitle,
                    isSame: isSame
                )

            case .cover:
                if isSame {
                    Text(ForkL10n.string("METADATA_PULL_COVER_SAME"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        VStack(spacing: 3) {
                            MangaCoverView(
                                source: source,
                                coverImage: currentDraft.cover ?? "",
                                width: 44,
                                height: 64
                            )
                            Text(ForkL10n.string("METADATA_PULL_COVER_NOW"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(spacing: 3) {
                            MangaCoverView(
                                source: nil,
                                coverImage: activePulledCoverUrl ?? "",
                                width: 44,
                                height: 64
                            )
                            .id(activePulledCoverUrl ?? "")
                            Text(ForkL10n.string("METADATA_PULL_COVER_MB"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.top, 2)
                }

            case .authors:
                textDiffBody(
                    current: MangaMetadataService.formatPersonList(currentDraft.authors),
                    incoming: MangaMetadataService.formatPersonList(activePulledAuthors),
                    isSame: isSame
                )

            case .artists:
                textDiffBody(
                    current: MangaMetadataService.formatPersonList(currentDraft.artists),
                    incoming: MangaMetadataService.formatPersonList(activePulledArtists),
                    isSame: isSame
                )

            case .status:
                textDiffBody(
                    current: currentDraft.status.title,
                    incoming: metadata.status?.title ?? "",
                    isSame: isSame
                )

            case .description:
                textDiffBody(
                    current: currentDraft.description ?? "",
                    incoming: activePulledDescription ?? "",
                    isSame: isSame,
                    lineLimit: 4
                )

            case .tags:
                textDiffBody(
                    current: currentDraft.tags.joined(separator: ", "),
                    incoming: metadata.tags.joined(separator: ", "),
                    isSame: isSame,
                    lineLimit: 3
                )
        }
    }

    @ViewBuilder
    func fieldAccessoryControls(for field: MetadataEditableField) -> some View {
        switch field {
            case .title:
                if !metadata.titleOptions.isEmpty {
                    QuickLanguageChipStrip(
                        options: quickTitleOptions,
                        selectedId: selectedTitleOption?.id,
                        selectedLanguageCode: selectedTitleOption?.languageCode,
                        allCount: metadata.titleOptions.count,
                        languageCode: \.languageCode,
                        onSelect: selectTitleOption,
                        onShowAll: { showingTitlePicker = true }
                    )
                }

            case .cover:
                if totalCoverCount > 1 {
                    Button {
                        showingCoverPicker = true
                    } label: {
                        Label(
                            ForkL10n.format("METADATA_COVERS_CHOOSE_FORMAT", totalCoverCount),
                            systemImage: "photo.on.rectangle.angled"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                } else if !metadata.hasLoadedInitialCovers && metadata.coverUrl != nil {
                    Button {
                        showingCoverPicker = true
                    } label: {
                        Label(
                            ForkL10n.string("METADATA_COVERS_BROWSE"),
                            systemImage: "photo.on.rectangle.angled"
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 2)
                }

            case .authors:
                if hasAuthorScriptToggle {
                    personScriptToggle(
                        useNative: Binding(
                            get: { useNativeAuthors },
                            set: { newValue in
                                useNativeAuthors = newValue
                                syncFieldCheckbox(for: .authors)
                            }
                        )
                    )
                }

            case .artists:
                if hasArtistScriptToggle {
                    personScriptToggle(
                        useNative: Binding(
                            get: { useNativeArtists },
                            set: { newValue in
                                useNativeArtists = newValue
                                syncFieldCheckbox(for: .artists)
                            }
                        )
                    )
                }

            case .description:
                if metadata.descriptionOptions.count > 1 {
                    QuickLanguageChipStrip(
                        options: quickDescriptionOptions,
                        selectedId: selectedDescriptionOption?.id,
                        selectedLanguageCode: selectedDescriptionOption?.languageCode,
                        allCount: metadata.descriptionOptions.count,
                        languageCode: \.languageCode,
                        onSelect: selectDescriptionOption,
                        onShowAll: { showingDescriptionPicker = true }
                    )
                }

            default:
                EmptyView()
        }
    }

    func personScriptToggle(useNative: Binding<Bool>) -> some View {
        HStack(spacing: 6) {
            scriptChip(
                title: ForkL10n.string("METADATA_PERSON_SCRIPT_ORIGINAL"),
                isSelected: useNative.wrappedValue
            ) {
                useNative.wrappedValue = true
            }
            scriptChip(
                title: ForkL10n.string("METADATA_PERSON_SCRIPT_ENGLISH"),
                isSelected: !useNative.wrappedValue
            ) {
                useNative.wrappedValue = false
            }
        }
        .padding(.top, 2)
    }

    func scriptChip(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .background(
                    isSelected
                        ? Color.accentColor.opacity(0.16)
                        : Color(uiColor: .secondarySystemFill)
                )
                .overlay(
                    Capsule()
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.clear,
                            lineWidth: 1
                        )
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    func textDiffBody(
        current: String,
        incoming: String,
        isSame: Bool,
        lineLimit: Int? = nil
    ) -> some View {
        let emptyPlaceholder = ForkL10n.string("METADATA_PULL_EMPTY_VALUE")
        if isSame {
            Text(incoming.isEmpty ? emptyPlaceholder : incoming)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
        } else {
            Text(current.isEmpty ? emptyPlaceholder : current)
                .strikethrough()
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Text(incoming.isEmpty ? emptyPlaceholder : incoming)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
        }
    }

    func selectTitleOption(_ option: TrackerTitleOption) {
        hasManuallyPickedTitle = true
        selectedTitleOption = option
        syncFieldCheckbox(for: .title)
    }

    func selectDescriptionOption(_ option: TrackerDescriptionOption) {
        hasManuallyPickedDescription = true
        selectedDescriptionOption = option
        syncFieldCheckbox(for: .description)
    }

    func syncFieldCheckbox(for field: MetadataEditableField) {
        if fieldDiffers(field) {
            selectedFields.insert(field)
        } else {
            selectedFields.remove(field)
        }
    }

    func fieldDiffers(_ field: MetadataEditableField) -> Bool {
        Self.fieldDiffers(
            field,
            currentDraft: currentDraft,
            candidates: activeCandidates
        )
    }

    func sortedTitleOptions() -> [TrackerTitleOption] {
        let priorityMap = priorityRankMap()
        return metadata.titleOptions.sorted { lhs, rhs in
            let lRank = priorityMap[lhs.languageCode.lowercased()] ?? Int.max
            let rRank = priorityMap[rhs.languageCode.lowercased()] ?? Int.max
            if lRank != rRank { return lRank < rRank }
            if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary }
            if lhs.languageCode != rhs.languageCode {
                return lhs.languageCode.localizedCaseInsensitiveCompare(rhs.languageCode) == .orderedAscending
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func sortedDescriptionOptions() -> [TrackerDescriptionOption] {
        let priorityMap = priorityRankMap()
        return metadata.descriptionOptions.sorted { lhs, rhs in
            let lRank = priorityMap[lhs.languageCode.lowercased()] ?? Int.max
            let rRank = priorityMap[rhs.languageCode.lowercased()] ?? Int.max
            if lRank != rRank { return lRank < rRank }
            if lhs.languageCode != rhs.languageCode {
                return lhs.languageCode.localizedCaseInsensitiveCompare(rhs.languageCode) == .orderedAscending
            }
            return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
        }
    }

    func priorityRankMap() -> [String: Int] {
        Dictionary(
            priorityOrder.enumerated().map { ($0.element.lowercased(), $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    func label(for field: MetadataEditableField) -> String {
        switch field {
            case .title: ForkL10n.string("METADATA_FIELD_TITLE")
            case .cover: ForkL10n.string("METADATA_SECTION_COVER")
            case .authors: ForkL10n.string("METADATA_FIELD_AUTHORS")
            case .artists: ForkL10n.string("METADATA_FIELD_ARTISTS")
            case .status: ForkL10n.string("METADATA_FIELD_STATUS")
            case .description: ForkL10n.string("METADATA_SECTION_DESCRIPTION")
            case .tags: ForkL10n.string("METADATA_SECTION_TAGS")
        }
    }
}

extension MangaBakaMetadataPullSheet {
    struct PullFieldCandidates: Equatable, Sendable {
        let title: String
        let coverUrl: String?
        let authors: [String]
        let artists: [String]
        let status: AidokuRunner.PublishingStatus?
        let description: String?
        let tags: [String]
    }

    static func fieldDiffers(
        _ field: MetadataEditableField,
        currentDraft: MangaMetadataSnapshot,
        candidates: PullFieldCandidates
    ) -> Bool {
        switch field {
            case .title:
                let next = candidates.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return !next.isEmpty && currentDraft.title != next
            case .cover:
                guard let next = candidates.coverUrl, MangaMetadataService.isValidRemoteCoverURL(next) else {
                    return false
                }
                return currentDraft.cover != next
            case .authors:
                return !candidates.authors.isEmpty && currentDraft.authors != candidates.authors
            case .artists:
                return !candidates.artists.isEmpty && currentDraft.artists != candidates.artists
            case .status:
                guard let nextStatus = candidates.status, nextStatus != .unknown else { return false }
                return currentDraft.status != nextStatus
            case .description:
                let nextDesc = candidates.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !nextDesc.isEmpty else { return false }
                return (currentDraft.description ?? "") != nextDesc
            case .tags:
                return !candidates.tags.isEmpty && currentDraft.tags != candidates.tags
        }
    }

    static func defaultSelectedFields(
        currentDraft: MangaMetadataSnapshot,
        candidates: PullFieldCandidates
    ) -> Set<MetadataEditableField> {
        Set(
            MetadataEditableField.allCases.filter {
                fieldDiffers(
                    $0,
                    currentDraft: currentDraft,
                    candidates: candidates
                )
            }
        )
    }

    static func fieldDiffers(
        _ field: MetadataEditableField,
        currentDraft: MangaMetadataSnapshot,
        metadata: TrackerMangaMetadata,
        selectedTitle: String
    ) -> Bool {
        let candidates = PullFieldCandidates(
            title: selectedTitle,
            coverUrl: metadata.coverUrl,
            authors: metadata.authors,
            artists: metadata.artists,
            status: metadata.status,
            description: metadata.description,
            tags: metadata.tags
        )
        return fieldDiffers(field, currentDraft: currentDraft, candidates: candidates)
    }

    static func defaultSelectedFields(
        currentDraft: MangaMetadataSnapshot,
        metadata: TrackerMangaMetadata,
        selectedTitle: String
    ) -> Set<MetadataEditableField> {
        let candidates = PullFieldCandidates(
            title: selectedTitle,
            coverUrl: metadata.coverUrl,
            authors: metadata.authors,
            artists: metadata.artists,
            status: metadata.status,
            description: metadata.description,
            tags: metadata.tags
        )
        return defaultSelectedFields(currentDraft: currentDraft, candidates: candidates)
    }
}

private struct QuickLanguageChipStrip<Option: Identifiable>: View {
    let options: [Option]
    let selectedId: Option.ID?
    let selectedLanguageCode: String?
    let allCount: Int
    let languageCode: (Option) -> String
    let onSelect: (Option) -> Void
    let onShowAll: () -> Void

    var body: some View {
        let selectedInQuick = options.contains { $0.id == selectedId }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options) { option in
                    let isSelected = option.id == selectedId
                    Button {
                        onSelect(option)
                    } label: {
                        Text(TitleLanguagePriorityStore.shortLabel(for: languageCode(option)))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            .background(
                                isSelected
                                    ? Color.accentColor.opacity(0.16)
                                    : Color(uiColor: .secondarySystemFill)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(
                                        isSelected ? Color.accentColor : Color.clear,
                                        lineWidth: 1
                                    )
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onShowAll) {
                    let buttonText = if !selectedInQuick, let selectedLanguageCode {
                        "\(TitleLanguagePriorityStore.shortLabel(for: selectedLanguageCode)) ▾"
                    } else {
                        "\(ForkL10n.format("METADATA_PULL_ALL_TITLES_FORMAT", allCount)) ▾"
                    }
                    Text(buttonText)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .foregroundStyle(!selectedInQuick ? Color.accentColor : Color.secondary)
                        .background(
                            !selectedInQuick
                                ? Color.accentColor.opacity(0.16)
                                : Color(uiColor: .secondarySystemFill)
                        )
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
    }
}

private struct TitleVariantPickerSheet: View {
    let options: [TrackerTitleOption]
    let selectedOption: TrackerTitleOption?
    let priorityStore: TitleLanguagePriorityStore
    let onSelect: (TrackerTitleOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredOptions: [TrackerTitleOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter { option in
            let langName = TitleLanguagePriorityStore.displayName(for: option.languageCode)
            return option.title.localizedCaseInsensitiveContains(query)
                || option.languageCode.localizedCaseInsensitiveContains(query)
                || langName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        PlatformNavigationStack {
            List {
                if filteredOptions.isEmpty {
                    Text(ForkL10n.string("METADATA_TITLE_PICKER_EMPTY"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(filteredOptions) { option in
                        Button {
                            onSelect(option)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(option.title)
                                        .font(.body)
                                        .foregroundStyle(.primary)

                                    HStack(spacing: 6) {
                                        Text(option.languageCode)
                                            .font(.caption2.monospaced().weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(uiColor: .secondarySystemFill))
                                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                                        Text(TitleLanguagePriorityStore.displayName(for: option.languageCode))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)

                                        ForEach(option.traits, id: \.self) { trait in
                                            Text("· \(trait)")
                                                .font(.caption)
                                                .foregroundStyle(.tint)
                                        }
                                    }
                                }

                                Spacer()

                                if option.id == selectedOption?.id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: ForkL10n.string("METADATA_TITLE_PICKER_SEARCH")
            )
            .navigationTitle(ForkL10n.string("METADATA_TITLE_PICKER_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ForkL10n.string("METADATA_DONE")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(ForkL10n.string("METADATA_TITLE_DEFAULT_ORDER_BUTTON")) {
                        TitleLanguagePriorityView(store: priorityStore)
                    }
                }
            }
        }
    }
}

private struct DescriptionVariantPickerSheet: View {
    let options: [TrackerDescriptionOption]
    let selectedOption: TrackerDescriptionOption?
    let priorityStore: TitleLanguagePriorityStore
    let onSelect: (TrackerDescriptionOption) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var filteredOptions: [TrackerDescriptionOption] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return options }
        return options.filter { option in
            let langName = TitleLanguagePriorityStore.displayName(for: option.languageCode)
            return option.text.localizedCaseInsensitiveContains(query)
                || option.languageCode.localizedCaseInsensitiveContains(query)
                || langName.localizedCaseInsensitiveContains(query)
                || option.sourceName.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        PlatformNavigationStack {
            List {
                if filteredOptions.isEmpty {
                    Text(ForkL10n.string("METADATA_DESCRIPTION_PICKER_EMPTY"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ForEach(filteredOptions) { option in
                        Button {
                            onSelect(option)
                            dismiss()
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(spacing: 6) {
                                        Text(option.languageCode)
                                            .font(.caption2.monospaced().weight(.semibold))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color(uiColor: .secondarySystemFill))
                                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

                                        Text(TitleLanguagePriorityStore.displayName(for: option.languageCode))
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)

                                        Text("· \(option.sourceName)")
                                            .font(.caption)
                                            .foregroundStyle(.tint)
                                    }

                                    Text(option.text)
                                        .font(.footnote)
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                }

                                Spacer()

                                if option.id == selectedOption?.id {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(.tint)
                                        .padding(.top, 2)
                                }
                            }
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: ForkL10n.string("METADATA_DESCRIPTION_PICKER_SEARCH")
            )
            .navigationTitle(ForkL10n.string("METADATA_DESCRIPTION_PICKER_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ForkL10n.string("METADATA_DONE")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink(ForkL10n.string("METADATA_TITLE_DEFAULT_ORDER_BUTTON")) {
                        TitleLanguagePriorityView(store: priorityStore)
                    }
                }
            }
        }
    }
}
