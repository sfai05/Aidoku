//
//  EditMetadataViewModel.swift
//  Aidoku
//
//  Created by Dokuha on 11/27/26.
//

import AidokuRunner
import Combine
import Foundation
import UIKit

@MainActor
final class EditMetadataViewModel: ObservableObject {
    let source: AidokuRunner.Source?
    @Published private(set) var manga: AidokuRunner.Manga

    @Published var coverUrl: String?
    @Published var pendingCoverImage: UIImage?
    @Published var coverUrlInput: String = ""
    @Published var coverUrlValidationError: String?

    @Published var title: String
    @Published var authorsText: String
    @Published var artistsText: String
    @Published var status: AidokuRunner.PublishingStatus
    @Published var contentRating: AidokuRunner.ContentRating
    @Published var descriptionText: String
    @Published var tags: [String]
    @Published var newTagText: String = ""

    @Published private(set) var initialEditedKeys: EditedKeys = []
    @Published private(set) var workingEditedKeys: EditedKeys = []
    @Published private(set) var modifiedFields: Set<MetadataEditableField> = []
    @Published private(set) var resetFields: Set<MetadataEditableField> = []

    @Published private(set) var mangaBakaTrackItem: TrackItem?
    @Published private(set) var isLoadingInitial = false
    @Published private(set) var isFetchingTrackerMetadata = false
    @Published private(set) var isSaving = false

    @Published var pulledMetadata: TrackerMangaMetadata?
    @Published var errorMessage: String?

    let languagePriorityStore: TitleLanguagePriorityStore
    let metadataProvider: TrackerMetadataProvider
    private var baselineSnapshot: MangaMetadataSnapshot
    private var cancellables = Set<AnyCancellable>()
    private var hasLoaded = false

    init(
        source: AidokuRunner.Source?,
        manga: AidokuRunner.Manga,
        initialEditedKeys: EditedKeys = [],
        metadataProvider: TrackerMetadataProvider = MangaBakaMetadataProvider(),
        languagePriorityStore: TitleLanguagePriorityStore = .shared
    ) {
        self.source = source
        self.manga = manga
        self.metadataProvider = metadataProvider
        self.languagePriorityStore = languagePriorityStore

        let initial = MangaMetadataSnapshot(manga: manga, editedKeys: initialEditedKeys)
        self.baselineSnapshot = initial
        self.initialEditedKeys = initialEditedKeys
        self.workingEditedKeys = initialEditedKeys
        self.coverUrl = initial.cover
        self.coverUrlInput = initial.cover ?? ""
        self.title = initial.title
        self.authorsText = MangaMetadataService.formatPersonList(initial.authors)
        self.artistsText = MangaMetadataService.formatPersonList(initial.artists)
        self.status = initial.status
        self.contentRating = initial.contentRating
        self.descriptionText = initial.description ?? ""
        self.tags = initial.tags

        observeTrackerUpdates()
    }

    var currentSnapshot: MangaMetadataSnapshot {
        MangaMetadataSnapshot(
            cover: coverUrl,
            title: title,
            authors: MangaMetadataService.parsePersonList(authorsText),
            artists: MangaMetadataService.parsePersonList(artistsText),
            status: status,
            contentRating: contentRating,
            description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : descriptionText,
            tags: tags,
            editedKeys: workingEditedKeys
        )
    }

    var canSave: Bool {
        let titleValid = resetFields.contains(.title)
            || !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return titleValid && hasPendingChanges && !isSaving
    }

    var hasPendingChanges: Bool {
        !modifiedFields.isEmpty || !resetFields.isEmpty || pendingCoverImage != nil
    }

    var hasAnyLockedOrModifiedFields: Bool {
        let basicMask = MetadataEditableField.allCases.reduce(into: EditedKeys()) { $0.insert($1.editedKey) }
        return !workingEditedKeys.isDisjoint(with: basicMask) || hasPendingChanges
    }

    var isLocalCoverActive: Bool {
        pendingCoverImage != nil || (coverUrl?.hasPrefix("aidoku-image://") == true)
    }

    var canResetToSourceDefaults: Bool {
        !manga.isLocal() && source != nil
    }

    func canResetField(_ field: MetadataEditableField) -> Bool {
        canResetToSourceDefaults ? isFieldEdited(field) : modifiedFields.contains(field)
    }

    func isFieldEdited(_ field: MetadataEditableField) -> Bool {
        workingEditedKeys.contains(field.editedKey)
    }

    func isFieldPendingReset(_ field: MetadataEditableField) -> Bool {
        resetFields.contains(field)
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoadingInitial = true
        defer { isLoadingInitial = false }

        let loaded = await MangaMetadataService.loadInitialState(for: manga)
        applyBaseline(loaded.snapshot)
        mangaBakaTrackItem = loaded.mangaBakaTrackItem
    }

    func refreshTrackerLink() async {
        mangaBakaTrackItem = await MangaMetadataService.fetchMangaBakaTrackItem(for: manga.identifier)
    }

    func onTitleChanged(_ newValue: String) {
        if title != newValue {
            title = newValue
        }
        reconcileTextField(.title)
    }

    func onAuthorsChanged(_ newValue: String) {
        if authorsText != newValue {
            authorsText = newValue
        }
        reconcileTextField(.authors)
    }

    func onArtistsChanged(_ newValue: String) {
        if artistsText != newValue {
            artistsText = newValue
        }
        reconcileTextField(.artists)
    }

    func onStatusChanged(_ newValue: AidokuRunner.PublishingStatus) {
        if status != newValue {
            status = newValue
        }
        reconcileField(.status, matchesBaseline: status == baselineSnapshot.status)
    }

    func onContentRatingChanged(_ newValue: AidokuRunner.ContentRating) {
        let normalized = MangaMetadataService.normalizedContentRating(newValue)
        if contentRating != normalized {
            contentRating = normalized
        }
        reconcileField(.contentRating, matchesBaseline: contentRating == baselineSnapshot.contentRating)
    }

    func onDescriptionChanged(_ newValue: String) {
        if descriptionText != newValue {
            descriptionText = newValue
        }
        reconcileTextField(.description)
    }

    func addTag() {
        let trimmed = newTagText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            newTagText = ""
            return
        }
        if !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            tags.append(trimmed)
        }
        newTagText = ""
        reconcileField(.tags, matchesBaseline: tags == baselineSnapshot.tags)
    }

    func removeTag(_ tag: String) {
        tags.removeAll { $0 == tag }
        reconcileField(.tags, matchesBaseline: tags == baselineSnapshot.tags)
    }

    func applyCoverImage(_ image: UIImage) {
        pendingCoverImage = image
        coverUrlValidationError = nil
        markEdited(.cover)
    }

    @discardableResult
    func applyCoverURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MangaMetadataService.isValidRemoteCoverURL(trimmed) else {
            coverUrlValidationError = ForkL10n.string("METADATA_ERROR_INVALID_COVER_URL")
            return false
        }
        coverUrlValidationError = nil
        pendingCoverImage = nil
        coverUrl = trimmed
        coverUrlInput = trimmed
        reconcileField(.cover, matchesBaseline: coverUrl == baselineSnapshot.cover)
        return true
    }

    func resetField(_ field: MetadataEditableField) {
        switch field {
            case .cover:
                pendingCoverImage = nil
                coverUrlValidationError = nil
                coverUrl = baselineSnapshot.cover
                coverUrlInput = baselineSnapshot.cover ?? ""
            case .title:
                title = baselineSnapshot.title
            case .authors:
                authorsText = MangaMetadataService.formatPersonList(baselineSnapshot.authors)
            case .artists:
                artistsText = MangaMetadataService.formatPersonList(baselineSnapshot.artists)
            case .status:
                status = baselineSnapshot.status
            case .contentRating:
                contentRating = baselineSnapshot.contentRating
            case .description:
                descriptionText = baselineSnapshot.description ?? ""
            case .tags:
                tags = baselineSnapshot.tags
        }

        modifiedFields.remove(field)
        if canResetToSourceDefaults {
            workingEditedKeys.remove(field.editedKey)
            if initialEditedKeys.contains(field.editedKey) {
                resetFields.insert(field)
            } else {
                resetFields.remove(field)
            }
        } else {
            resetFields.remove(field)
            if initialEditedKeys.contains(field.editedKey) {
                workingEditedKeys.insert(field.editedKey)
            } else {
                workingEditedKeys.remove(field.editedKey)
            }
        }
    }

    func resetAllToSourceDefaults() {
        for field in MetadataEditableField.allCases {
            resetField(field)
        }
    }

    func pullFromMangaBaka() async {
        guard let trackItem = mangaBakaTrackItem, !isFetchingTrackerMetadata else { return }
        isFetchingTrackerMetadata = true
        errorMessage = nil
        defer { isFetchingTrackerMetadata = false }

        do {
            pulledMetadata = try await metadataProvider.fetchMetadata(trackId: trackItem.id)
        } catch {
            errorMessage = ForkL10n.format("METADATA_TRACKER_PULL_FAILED_FORMAT", error.localizedDescription)
        }
    }

    func applyPulledSelection(_ selection: TrackerMetadataSelection, from metadata: TrackerMangaMetadata) {
        for field in selection.selectedFields {
            switch field {
                case .title:
                    let chosen = selection.selectedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !chosen.isEmpty {
                        title = chosen
                        markEdited(.title)
                    }
                case .cover:
                    let resolvedCover = selection.selectedCoverUrl ?? metadata.coverUrl
                    if let remoteCover = resolvedCover, MangaMetadataService.isValidRemoteCoverURL(remoteCover) {
                        pendingCoverImage = nil
                        coverUrl = remoteCover
                        coverUrlInput = remoteCover
                        coverUrlValidationError = nil
                        markEdited(.cover)
                    }
                case .authors:
                    authorsText = MangaMetadataService.formatPersonList(selection.selectedAuthors ?? metadata.authors)
                    markEdited(.authors)
                case .artists:
                    artistsText = MangaMetadataService.formatPersonList(selection.selectedArtists ?? metadata.artists)
                    markEdited(.artists)
                case .status:
                    if let pulledStatus = metadata.status {
                        status = pulledStatus
                        markEdited(.status)
                    }
                case .contentRating:
                    if let pulledRating = metadata.contentRating, pulledRating != .unknown {
                        contentRating = MangaMetadataService.normalizedContentRating(pulledRating)
                        markEdited(.contentRating)
                    }
                case .description:
                    descriptionText = (selection.selectedDescription ?? metadata.description) ?? ""
                    markEdited(.description)
                case .tags:
                    tags = metadata.tags
                    markEdited(.tags)
            }
        }
    }

    func save() async -> MetadataSaveResult? {
        guard canSave else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            let request = MetadataSaveRequest(
                manga: manga,
                source: source,
                snapshot: currentSnapshot,
                editedFields: modifiedFields,
                resetFields: resetFields,
                pendingCoverImage: pendingCoverImage
            )
            let result = try await MangaMetadataService.save(request)
            manga = result.updatedManga
            applyBaseline(MangaMetadataSnapshot(manga: result.updatedManga, editedKeys: result.editedKeys))
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }
}

private extension EditMetadataViewModel {
    func observeTrackerUpdates() {
        NotificationCenter.default.publisher(for: .updateTrackers)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.refreshTrackerLink()
                }
            }
            .store(in: &cancellables)
    }

    func applyBaseline(_ snapshot: MangaMetadataSnapshot) {
        baselineSnapshot = snapshot
        initialEditedKeys = snapshot.editedKeys
        workingEditedKeys = snapshot.editedKeys
        modifiedFields = []
        resetFields = []
        pendingCoverImage = nil
        coverUrlValidationError = nil

        coverUrl = snapshot.cover
        coverUrlInput = snapshot.cover ?? ""
        title = snapshot.title
        authorsText = MangaMetadataService.formatPersonList(snapshot.authors)
        artistsText = MangaMetadataService.formatPersonList(snapshot.artists)
        status = snapshot.status
        contentRating = snapshot.contentRating
        descriptionText = snapshot.description ?? ""
        tags = snapshot.tags
    }

    func markEdited(_ field: MetadataEditableField) {
        resetFields.remove(field)
        modifiedFields.insert(field)
        workingEditedKeys.insert(field.editedKey)
    }

    func reconcileTextField(_ field: MetadataEditableField) {
        let snapshot = currentSnapshot
        let matches: Bool = switch field {
            case .title:
                snapshot.title == baselineSnapshot.title
            case .authors:
                snapshot.authors == baselineSnapshot.authors
            case .artists:
                snapshot.artists == baselineSnapshot.artists
            case .description:
                snapshot.description == baselineSnapshot.description
            default:
                false
        }
        reconcileField(field, matchesBaseline: matches)
    }

    func reconcileField(_ field: MetadataEditableField, matchesBaseline: Bool) {
        resetFields.remove(field)
        if !initialEditedKeys.contains(field.editedKey) && matchesBaseline {
            modifiedFields.remove(field)
            workingEditedKeys.remove(field.editedKey)
        } else {
            modifiedFields.insert(field)
            workingEditedKeys.insert(field.editedKey)
        }
    }
}
