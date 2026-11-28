//
//  EditMetadataView.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import AidokuRunner
import SwiftUI
import UIKit

struct EditMetadataView: View {
    @StateObject private var viewModel: EditMetadataViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var showingCoverUrlField = false
    @State private var showingImagePicker = false
    @State private var pickedCoverImage: UIImage?
    @State private var showingTrackerSheet = false
    @State private var showingResetAllConfirm = false

    private let editableStatuses: [AidokuRunner.PublishingStatus] = [
        .ongoing,
        .completed,
        .hiatus,
        .cancelled,
        .unknown
    ]

    private let editableContentRatings: [AidokuRunner.ContentRating] = [
        .safe,
        .suggestive,
        .nsfw
    ]

    init(
        source: AidokuRunner.Source?,
        manga: AidokuRunner.Manga
    ) {
        self._viewModel = StateObject(
            wrappedValue: EditMetadataViewModel(source: source, manga: manga)
        )
    }

    var body: some View {
        PlatformNavigationStack {
            List {
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                trackerSection
                coverSection
                detailsSection
                descriptionSection
                tagsSection
                resetAllSection
            }
            .scrollDismissesKeyboardImmediately()
            .navigationTitle(ForkL10n.string("METADATA_EDIT_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ForkL10n.string("METADATA_CANCEL")) {
                        dismiss()
                    }
                    .disabled(viewModel.isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isSaving {
                        ProgressView()
                    } else {
                        Button(ForkL10n.string("METADATA_SAVE")) {
                            Task {
                                if await viewModel.save() != nil {
                                    dismiss()
                                }
                            }
                        }
                        .font(.body.weight(.semibold))
                        .disabled(!viewModel.canSave)
                    }
                }
            }
            .task {
                await viewModel.load()
            }
            .sheet(isPresented: $showingImagePicker) {
                ImagePicker(image: $pickedCoverImage)
                    .ignoresSafeArea()
            }
            .onChange(of: pickedCoverImage) { newImage in
                guard let newImage else { return }
                viewModel.applyCoverImage(newImage)
                showingCoverUrlField = false
                pickedCoverImage = nil
            }
            .sheet(isPresented: $showingTrackerSheet) {
                TrackerLinkSheet(manga: viewModel.manga)
            }
            .sheet(item: $viewModel.pulledMetadata) { metadata in
                MangaBakaMetadataPullSheet(
                    source: viewModel.source,
                    currentDraft: viewModel.currentSnapshot,
                    metadata: metadata,
                    dependencies: .init(
                        languagePriorityStore: viewModel.languagePriorityStore,
                        metadataProvider: viewModel.metadataProvider
                    ),
                    onApply: { selection in
                        viewModel.applyPulledSelection(selection, from: metadata)
                    }
                )
            }
            .alert(
                ForkL10n.string("METADATA_RESET_ALL_CONFIRM_TITLE"),
                isPresented: $showingResetAllConfirm
            ) {
                Button(ForkL10n.string("METADATA_CANCEL"), role: .cancel) {}
                Button(ForkL10n.string("METADATA_RESET_FIELD"), role: .destructive) {
                    viewModel.resetAllToSourceDefaults()
                }
            } message: {
                Text(ForkL10n.string("METADATA_RESET_ALL_CONFIRM_MESSAGE"))
            }
        }
    }
}

private extension EditMetadataView {
    var trackerSection: some View {
        Section(ForkL10n.string("METADATA_SECTION_TRACKER")) {
            HStack(spacing: 12) {
                trackerIconView

                VStack(alignment: .leading, spacing: 2) {
                    if let trackItem = viewModel.mangaBakaTrackItem {
                        Text(TrackerManager.mangabaka.name)
                            .font(.subheadline.weight(.semibold))
                        Text(
                            ForkL10n.format(
                                "METADATA_MANGABAKA_LINKED_FORMAT",
                                trackItem.title ?? trackItem.id
                            )
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    } else {
                        Text(ForkL10n.string("METADATA_MANGABAKA_NOT_LINKED"))
                            .font(.subheadline.weight(.semibold))
                        Text(ForkL10n.string("METADATA_MANGABAKA_NOT_LINKED_SUBTITLE"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if viewModel.mangaBakaTrackItem != nil {
                    if viewModel.isFetchingTrackerMetadata {
                        ProgressView()
                    } else {
                        Button(ForkL10n.string("METADATA_MANGABAKA_PULL_BUTTON")) {
                            Task {
                                await viewModel.pullFromMangaBaka()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                } else {
                    Button(ForkL10n.string("METADATA_MANGABAKA_TRACK_BUTTON")) {
                        showingTrackerSheet = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    var trackerIconView: some View {
        let icon = TrackerManager.mangabaka.icon
        let isLinked = viewModel.mangaBakaTrackItem != nil
        if let icon {
            Image(uiImage: icon)
                .resizable()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .saturation(isLinked ? 1 : 0)
                .opacity(isLinked ? 1 : 0.55)
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isLinked ? Color.accentColor : Color(uiColor: .secondarySystemFill))
                .frame(width: 36, height: 36)
                .overlay {
                    Text("MB")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(isLinked ? .white : .secondary)
                }
        }
    }

    var coverSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    coverPreview
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button(ForkL10n.string("METADATA_COVER_CHOOSE_PHOTO")) {
                                showingImagePicker = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(ForkL10n.string("METADATA_COVER_IMAGE_URL")) {
                                withAnimation {
                                    showingCoverUrlField.toggle()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text(coverStorageHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if showingCoverUrlField {
                    HStack(spacing: 8) {
                        TextField(
                            ForkL10n.string("METADATA_COVER_URL_PLACEHOLDER"),
                            text: $viewModel.coverUrlInput
                        )
                        .font(.footnote.monospaced())
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)

                        Button(ForkL10n.string("METADATA_COVER_SET_URL")) {
                            if viewModel.applyCoverURL(viewModel.coverUrlInput) {
                                withAnimation {
                                    showingCoverUrlField = false
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    if let urlError = viewModel.coverUrlValidationError {
                        Text(urlError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            fieldSectionHeader(
                title: ForkL10n.string("METADATA_SECTION_COVER"),
                field: .cover
            )
        }
    }

    @ViewBuilder
    var coverPreview: some View {
        if let pendingCoverImage = viewModel.pendingCoverImage {
            Image(uiImage: pendingCoverImage)
                .resizable()
                .scaledToFill()
                .frame(width: 62, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color(uiColor: .quaternarySystemFill), lineWidth: 1)
                )
        } else {
            MangaCoverView(
                source: viewModel.source,
                coverImage: viewModel.coverUrl ?? "",
                width: 62,
                height: 92
            )
            .id(viewModel.coverUrl ?? "")
        }
    }

    var coverStorageHint: String {
        if viewModel.isLocalCoverActive {
            return ForkL10n.string("METADATA_COVER_LOCAL_HINT")
        }
        if viewModel.isFieldEdited(.cover) {
            return ForkL10n.string("METADATA_COVER_REMOTE_HINT")
        }
        return ForkL10n.string("METADATA_COVER_DEFAULT_HINT")
    }

    var detailsSection: some View {
        Section(ForkL10n.string("METADATA_SECTION_DETAILS")) {
            VStack(alignment: .leading, spacing: 6) {
                fieldInlineHeader(
                    title: ForkL10n.string("METADATA_FIELD_TITLE"),
                    field: .title
                )
                TextField(
                    ForkL10n.string("METADATA_FIELD_TITLE_PLACEHOLDER"),
                    text: Binding(
                        get: { viewModel.title },
                        set: { viewModel.onTitleChanged($0) }
                    )
                )
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                fieldInlineHeader(
                    title: ForkL10n.string("METADATA_FIELD_AUTHORS"),
                    field: .authors
                )
                TextField(
                    ForkL10n.string("METADATA_FIELD_AUTHORS_PLACEHOLDER"),
                    text: Binding(
                        get: { viewModel.authorsText },
                        set: { viewModel.onAuthorsChanged($0) }
                    )
                )
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                fieldInlineHeader(
                    title: ForkL10n.string("METADATA_FIELD_ARTISTS"),
                    field: .artists
                )
                TextField(
                    ForkL10n.string("METADATA_FIELD_ARTISTS_PLACEHOLDER"),
                    text: Binding(
                        get: { viewModel.artistsText },
                        set: { viewModel.onArtistsChanged($0) }
                    )
                )
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                fieldInlineHeader(
                    title: ForkL10n.string("METADATA_FIELD_STATUS"),
                    field: .status
                )
                Picker(
                    ForkL10n.string("METADATA_FIELD_STATUS"),
                    selection: Binding(
                        get: { viewModel.status },
                        set: { viewModel.onStatusChanged($0) }
                    )
                ) {
                    ForEach(editableStatuses, id: \.self) { item in
                        Text(item.title).tag(item)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                fieldInlineHeader(
                    title: ForkL10n.string("METADATA_FIELD_CONTENT_RATING"),
                    field: .contentRating
                )
                let ratingPicker = Picker(
                    ForkL10n.string("METADATA_FIELD_CONTENT_RATING"),
                    selection: Binding(
                        get: { viewModel.contentRating },
                        set: { viewModel.onContentRatingChanged($0) }
                    )
                ) {
                    ForEach(editableContentRatings, id: \.self) { rating in
                        Text(rating.title).tag(rating)
                    }
                }
                if dynamicTypeSize.isAccessibilitySize {
                    ratingPicker
                        .labelsHidden()
                        .pickerStyle(.menu)
                } else {
                    ratingPicker
                        .pickerStyle(.segmented)
                }
            }
            .padding(.vertical, 2)
        }
    }

    var descriptionSection: some View {
        Section {
            ZStack(alignment: .topLeading) {
                if viewModel.descriptionText.isEmpty {
                    Text(ForkL10n.string("METADATA_FIELD_DESCRIPTION_PLACEHOLDER"))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }
                TextEditor(
                    text: Binding(
                        get: { viewModel.descriptionText },
                        set: { viewModel.onDescriptionChanged($0) }
                    )
                )
                .frame(minHeight: 110)
            }
        } header: {
            fieldSectionHeader(
                title: ForkL10n.string("METADATA_SECTION_DESCRIPTION"),
                field: .description
            )
        }
    }

    var tagsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                if viewModel.tags.isEmpty {
                    Text(ForkL10n.string("METADATA_NO_TAGS"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    WrappingHStack(viewModel.tags, id: \.self) { tag in
                        HStack(spacing: 4) {
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            Button {
                                viewModel.removeTag(tag)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color(uiColor: .secondarySystemFill))
                        .clipShape(Capsule())
                        .padding([.trailing, .bottom], 6)
                    }
                }

                Divider()

                HStack(spacing: 8) {
                    TextField(
                        ForkL10n.string("METADATA_ADD_TAG_PLACEHOLDER"),
                        text: $viewModel.newTagText
                    )
                    .onSubmit {
                        viewModel.addTag()
                    }

                    Button(ForkL10n.string("METADATA_ADD_TAG_BUTTON")) {
                        viewModel.addTag()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.newTagText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.vertical, 4)
        } header: {
            fieldSectionHeader(
                title: ForkL10n.string("METADATA_SECTION_TAGS"),
                field: .tags
            )
        }
    }

    var resetAllSection: some View {
        Section {
            if viewModel.canResetToSourceDefaults {
                Button(role: .destructive) {
                    showingResetAllConfirm = true
                } label: {
                    Text(ForkL10n.string("METADATA_RESET_ALL_BUTTON"))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(!viewModel.hasAnyLockedOrModifiedFields)
            }
        } footer: {
            Text(
                ForkL10n.string(
                    viewModel.manga.isLocal()
                        ? "METADATA_EDIT_LOCAL_FOOTER"
                        : "METADATA_EDIT_FOOTER"
                )
            )
        }
    }

    func fieldInlineHeader(title: String, field: MetadataEditableField) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            fieldStatusBadge(for: field)

            Spacer()

            fieldResetButton(for: field)
        }
    }

    func fieldSectionHeader(title: String, field: MetadataEditableField) -> some View {
        HStack(spacing: 6) {
            Text(title)

            fieldStatusBadge(for: field)
                .textCase(nil)

            Spacer()

            fieldResetButton(for: field)
                .textCase(nil)
        }
    }

    @ViewBuilder
    func fieldStatusBadge(for field: MetadataEditableField) -> some View {
        if viewModel.isFieldPendingReset(field) {
            Text(ForkL10n.string("METADATA_BADGE_RESET_PENDING"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.15))
                .clipShape(Capsule())
        } else if viewModel.isFieldEdited(field) {
            Text(ForkL10n.string("METADATA_BADGE_EDITED"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.15))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    func fieldResetButton(for field: MetadataEditableField) -> some View {
        if viewModel.canResetField(field) {
            Button {
                viewModel.resetField(field)
            } label: {
                Label(ForkL10n.string("METADATA_RESET_FIELD"), systemImage: "arrow.counterclockwise")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct TrackerLinkSheet: View {
    let manga: AidokuRunner.Manga
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        PlatformNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(ForkL10n.string("METADATA_TRACKER_PICK_HINT"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    TrackerListView(manga: manga)
                }
                .padding(.top, 8)
            }
            .navigationTitle(NSLocalizedString("TRACKING"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    CloseButton {
                        dismiss()
                    }
                }
            }
        }
    }
}
