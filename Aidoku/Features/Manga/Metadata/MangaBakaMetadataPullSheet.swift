//
//  MangaBakaMetadataPullSheet.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import AidokuRunner
import SwiftUI

struct MangaBakaMetadataPullSheet: View {
    let source: AidokuRunner.Source?
    let currentDraft: MangaMetadataSnapshot
    let metadata: TrackerMangaMetadata
    let languagePriorityStore: TitleLanguagePriorityStore
    let onApply: (TrackerMetadataSelection) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedFields: Set<MetadataEditableField> = []
    @State private var selectedTitleOption: TrackerTitleOption?
    @State private var hasManuallyPickedTitle = false
    @State private var priorityOrder: [String]
    @State private var showingTitlePicker = false

    init(
        source: AidokuRunner.Source?,
        currentDraft: MangaMetadataSnapshot,
        metadata: TrackerMangaMetadata,
        languagePriorityStore: TitleLanguagePriorityStore = .shared,
        onApply: @escaping (TrackerMetadataSelection) -> Void
    ) {
        self.source = source
        self.currentDraft = currentDraft
        self.metadata = metadata
        self.languagePriorityStore = languagePriorityStore
        self.onApply = onApply

        let order = languagePriorityStore.priorityOrder
        let preferred = TitleLanguagePriorityStore.resolvePreferredTitle(
            from: metadata.titleOptions,
            defaultTitle: metadata.defaultTitle,
            priorityOrder: order
        )
        self._priorityOrder = State(initialValue: order)
        self._selectedTitleOption = State(initialValue: preferred)
        self._selectedFields = State(
            initialValue: Self.defaultSelectedFields(
                currentDraft: currentDraft,
                metadata: metadata,
                selectedTitle: preferred?.title ?? metadata.defaultTitle
            )
        )
    }

    private var activePulledTitle: String {
        selectedTitleOption?.title ?? metadata.defaultTitle
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
                                selectedTitle: activePulledTitle
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
                    priorityStore: languagePriorityStore,
                    onSelect: { option in
                        selectTitleOption(option)
                    }
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .forkTitleLanguagePriorityChanged)) { _ in
                priorityOrder = languagePriorityStore.priorityOrder
                if !hasManuallyPickedTitle {
                    let resolved = TitleLanguagePriorityStore.resolvePreferredTitle(
                        from: metadata.titleOptions,
                        defaultTitle: metadata.defaultTitle,
                        priorityOrder: priorityOrder
                    )
                    selectedTitleOption = resolved
                    syncTitleSelectionCheckbox()
                }
            }
        }
    }
}

private extension MangaBakaMetadataPullSheet {
    @ViewBuilder
    func diffRow(for field: MetadataEditableField) -> some View {
        let isSame = !fieldDiffers(field)
        let isChecked = !isSame && selectedFields.contains(field)

        Button {
            guard !isSame else { return }
            if selectedFields.contains(field) {
                selectedFields.remove(field)
            } else {
                selectedFields.insert(field)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 6) {
                    diffHeader(for: field, isSame: isSame)
                    diffContent(for: field, isSame: isSame)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isSame ? 0.6 : 1)
    }

    func diffHeader(for field: MetadataEditableField, isSame: Bool) -> some View {
        HStack(spacing: 6) {
            Text(label(for: field))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)

            if field == .title, let code = selectedTitleOption?.languageCode {
                Text(code)
                    .font(.caption2.monospaced().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(uiColor: .secondarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }

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
    func diffContent(for field: MetadataEditableField, isSame: Bool) -> some View {
        switch field {
            case .title:
                textDiffBody(
                    current: currentDraft.title,
                    incoming: activePulledTitle,
                    isSame: isSame
                )
                if !metadata.titleOptions.isEmpty {
                    titleLanguageStrip
                }

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
                                coverImage: metadata.coverUrl ?? "",
                                width: 44,
                                height: 64
                            )
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
                    incoming: MangaMetadataService.formatPersonList(metadata.authors),
                    isSame: isSame
                )

            case .artists:
                textDiffBody(
                    current: MangaMetadataService.formatPersonList(currentDraft.artists),
                    incoming: MangaMetadataService.formatPersonList(metadata.artists),
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
                    incoming: metadata.description ?? "",
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

    var titleLanguageStrip: some View {
        let selectedInQuick = quickTitleOptions.contains { $0.id == selectedTitleOption?.id }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quickTitleOptions) { option in
                    let isSelected = option.id == selectedTitleOption?.id
                    Button {
                        selectTitleOption(option)
                    } label: {
                        Text(TitleLanguagePriorityStore.shortLabel(for: option.languageCode))
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

                Button {
                    showingTitlePicker = true
                } label: {
                    let text = if !selectedInQuick, let code = selectedTitleOption?.languageCode {
                        "\(TitleLanguagePriorityStore.shortLabel(for: code)) ▾"
                    } else {
                        "\(ForkL10n.format("METADATA_PULL_ALL_TITLES_FORMAT", metadata.titleOptions.count)) ▾"
                    }
                    Text(text)
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

    func selectTitleOption(_ option: TrackerTitleOption) {
        hasManuallyPickedTitle = true
        selectedTitleOption = option
        syncTitleSelectionCheckbox()
    }

    func syncTitleSelectionCheckbox() {
        if fieldDiffers(.title) {
            selectedFields.insert(.title)
        } else {
            selectedFields.remove(.title)
        }
    }

    func fieldDiffers(_ field: MetadataEditableField) -> Bool {
        Self.fieldDiffers(
            field,
            currentDraft: currentDraft,
            metadata: metadata,
            selectedTitle: activePulledTitle
        )
    }

    func sortedTitleOptions() -> [TrackerTitleOption] {
        let priorityMap = Dictionary(
            priorityOrder.enumerated().map { ($0.element.lowercased(), $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
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
    static func fieldDiffers(
        _ field: MetadataEditableField,
        currentDraft: MangaMetadataSnapshot,
        metadata: TrackerMangaMetadata,
        selectedTitle: String
    ) -> Bool {
        switch field {
            case .title:
                let next = selectedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                return !next.isEmpty && currentDraft.title != next
            case .cover:
                guard let next = metadata.coverUrl, MangaMetadataService.isValidRemoteCoverURL(next) else {
                    return false
                }
                return currentDraft.cover != next
            case .authors:
                return !metadata.authors.isEmpty && currentDraft.authors != metadata.authors
            case .artists:
                return !metadata.artists.isEmpty && currentDraft.artists != metadata.artists
            case .status:
                guard let nextStatus = metadata.status, nextStatus != .unknown else { return false }
                return currentDraft.status != nextStatus
            case .description:
                guard let nextDesc = metadata.description, !nextDesc.isEmpty else { return false }
                return (currentDraft.description ?? "") != nextDesc
            case .tags:
                return !metadata.tags.isEmpty && currentDraft.tags != metadata.tags
        }
    }

    static func defaultSelectedFields(
        currentDraft: MangaMetadataSnapshot,
        metadata: TrackerMangaMetadata,
        selectedTitle: String
    ) -> Set<MetadataEditableField> {
        Set(
            MetadataEditableField.allCases.filter {
                fieldDiffers(
                    $0,
                    currentDraft: currentDraft,
                    metadata: metadata,
                    selectedTitle: selectedTitle
                )
            }
        )
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
