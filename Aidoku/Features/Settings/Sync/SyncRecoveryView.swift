//
//  SyncRecoveryView.swift
//  Aidoku
//

import SwiftUI

struct SyncRecoveryView: View {
    @ObservedObject var viewModel: SyncSettingsViewModel

    private enum RecoveryConfirmation: Identifiable {
        case forcePush
        case forcePullLatest
        case forcePullSnapshot(SyncSnapshotMetadata)
        case deleteSnapshot(SyncSnapshotMetadata)
        case cleanupSnapshots
        case resetCursor
        case resetAll

        var id: String {
            switch self {
                case .forcePush:
                    "forcePush"
                case .forcePullLatest:
                    "forcePullLatest"
                case let .forcePullSnapshot(meta):
                    "forcePull-\(meta.id)"
                case let .deleteSnapshot(meta):
                    "delete-\(meta.id)"
                case .cleanupSnapshots:
                    "cleanupSnapshots"
                case .resetCursor:
                    "resetCursor"
                case .resetAll:
                    "resetAll"
            }
        }
    }

    @State private var confirmation: RecoveryConfirmation?

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            Section {
                SyncBannerView(banner: SyncBannerMessage(
                    tone: .warning,
                    text: ForkL10n.string("SYNC_RECOVERY_WARNING")
                ))

                if let banner = viewModel.statusBanner {
                    SyncBannerView(banner: banner)
                }
            }

            Section(ForkL10n.string("SYNC_RECOVERY_ACTIONS_SECTION")) {
                Button {
                    Task {
                        await viewModel.syncNow()
                    }
                } label: {
                    Label(ForkL10n.string("SYNC_FORCE_SYNC_BUTTON"), systemImage: "arrow.clockwise")
                }
                .disabled(!viewModel.isEnabled || !viewModel.isSignedIn || viewModel.isBusy)

                Button(role: .destructive) {
                    confirmation = .forcePush
                } label: {
                    Label(ForkL10n.string("SYNC_FORCE_PUSH_BUTTON"), systemImage: "icloud.and.arrow.up")
                }
                .disabled(!viewModel.isEnabled || !viewModel.isSignedIn || viewModel.isBusy)

                Button(role: .destructive) {
                    confirmation = .forcePullLatest
                } label: {
                    Label(ForkL10n.string("SYNC_FORCE_PULL_LATEST_BUTTON"), systemImage: "icloud.and.arrow.down")
                }
                .disabled(!viewModel.isEnabled || !viewModel.isSignedIn || viewModel.isBusy)
            }

            Section {
                Button {
                    Task {
                        await viewModel.loadRemoteSnapshots()
                    }
                } label: {
                    HStack {
                        Label(ForkL10n.string("SYNC_SNAPSHOTS_REFRESH_BUTTON"), systemImage: "clock.arrow.circlepath")
                        Spacer()
                        if viewModel.isLoadingSnapshots {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                }
                .disabled(!viewModel.isSignedIn || viewModel.isLoadingSnapshots || viewModel.isBusy)

                if viewModel.remoteSnapshots.isEmpty {
                    Text(ForkL10n.string("SYNC_SNAPSHOTS_EMPTY"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.remoteSnapshots) { snapshot in
                        snapshotRow(snapshot)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    confirmation = .deleteSnapshot(snapshot)
                                } label: {
                                    Label(NSLocalizedString("DELETE"), systemImage: "trash")
                                }
                            }
                    }
                }

                Button {
                    confirmation = .cleanupSnapshots
                } label: {
                    Label(ForkL10n.string("SYNC_CLEANUP_SNAPSHOTS_BUTTON"), systemImage: "trash")
                }
                .disabled(!viewModel.isSignedIn || viewModel.isBusy)
            } header: {
                Text(ForkL10n.string("SYNC_SNAPSHOTS_SECTION"))
            }

            Section(ForkL10n.string("SYNC_SECTION_LOCAL_RESET")) {
                Button {
                    confirmation = .resetCursor
                } label: {
                    Label(ForkL10n.string("SYNC_RESET_CURSOR_BUTTON"), systemImage: "arrow.counterclockwise")
                }
                .disabled(viewModel.isBusy)

                Button(role: .destructive) {
                    confirmation = .resetAll
                } label: {
                    Label(ForkL10n.string("SYNC_RESET_ALL_BUTTON"), systemImage: "xmark.circle.fill")
                }
                .disabled(viewModel.isBusy)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(ForkL10n.string("SYNC_RECOVERY_TITLE"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if viewModel.isSignedIn && viewModel.remoteSnapshots.isEmpty {
                await viewModel.loadRemoteSnapshots()
            }
        }
        .alert(
            confirmationTitle,
            isPresented: Binding(
                get: { confirmation != nil },
                set: { isPresented in
                    if !isPresented {
                        confirmation = nil
                    }
                }
            ),
            presenting: confirmation
        ) { item in
            confirmationActions(for: item)
        } message: { item in
            Text(confirmationMessage(for: item))
        }
    }

    private func snapshotRow(_ snapshot: SyncSnapshotMetadata) -> some View {
        Button {
            confirmation = .forcePullSnapshot(snapshot)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(ForkL10n.format("SYNC_SNAPSHOT_ROW_FORMAT", snapshot.revision, displayDeviceName(snapshot)))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    if isLatestSnapshot(snapshot) {
                        Text(ForkL10n.string("SYNC_SNAPSHOT_LATEST_BADGE"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    Spacer()
                    Text(formattedSize(snapshot.sizeBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text(Self.dateFormatter.string(from: snapshot.createdAt))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(snapshot.checksum.prefix(8)))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .disabled(!viewModel.isEnabled || viewModel.isBusy)
    }

    private func isLatestSnapshot(_ snapshot: SyncSnapshotMetadata) -> Bool {
        let head = viewModel.remoteSnapshots.max { ($0.revision, $0.createdAt) < ($1.revision, $1.createdAt) }
        return snapshot.id == head?.id
    }

    private func displayDeviceName(_ snapshot: SyncSnapshotMetadata) -> String {
        snapshot.deviceName.isEmpty ? snapshot.deviceId : snapshot.deviceName
    }

    private func formattedSize(_ bytes: Int?) -> String {
        guard let bytes, bytes > 0 else {
            return ForkL10n.string("SYNC_UNKNOWN_SIZE")
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var confirmationTitle: String {
        guard let confirmation else { return "" }
        switch confirmation {
            case .forcePush:
                return ForkL10n.string("SYNC_FORCE_PUSH_TITLE")
            case .forcePullLatest:
                return ForkL10n.string("SYNC_FORCE_PULL_LATEST_TITLE")
            case let .forcePullSnapshot(snapshot):
                return ForkL10n.format("SYNC_FORCE_PULL_SNAPSHOT_TITLE_FORMAT", snapshot.revision)
            case let .deleteSnapshot(snapshot):
                return ForkL10n.format("SYNC_DELETE_SNAPSHOT_TITLE_FORMAT", snapshot.revision)
            case .cleanupSnapshots:
                return ForkL10n.string("SYNC_CLEANUP_CONFIRM_TITLE")
            case .resetCursor:
                return ForkL10n.string("SYNC_RESET_CURSOR_TITLE")
            case .resetAll:
                return ForkL10n.string("SYNC_RESET_ALL_TITLE")
        }
    }

    private func confirmationMessage(for item: RecoveryConfirmation) -> String {
        switch item {
            case .forcePush:
                return ForkL10n.string("SYNC_FORCE_PUSH_MESSAGE")
            case .forcePullLatest:
                return ForkL10n.string("SYNC_FORCE_PULL_LATEST_MESSAGE")
            case let .forcePullSnapshot(snapshot):
                if isLatestSnapshot(snapshot) {
                    return ForkL10n.string("SYNC_FORCE_PULL_LATEST_MESSAGE")
                }
                return ForkL10n.string("SYNC_FORCE_PULL_SNAPSHOT_MESSAGE")
            case let .deleteSnapshot(snapshot):
                if isLatestSnapshot(snapshot) {
                    return ForkL10n.string("SYNC_DELETE_HEAD_SNAPSHOT_MESSAGE")
                }
                return ForkL10n.string("SYNC_DELETE_SNAPSHOT_MESSAGE")
            case .cleanupSnapshots:
                return ForkL10n.format("SYNC_CLEANUP_CONFIRM_MESSAGE_FORMAT", viewModel.maxRemoteSnapshots)
            case .resetCursor:
                return ForkL10n.string("SYNC_RESET_CURSOR_MESSAGE")
            case .resetAll:
                return ForkL10n.string("SYNC_RESET_ALL_MESSAGE")
        }
    }

    @ViewBuilder
    private func confirmationActions(for item: RecoveryConfirmation) -> some View {
        switch item {
            case .forcePush:
                Button(ForkL10n.string("SYNC_FORCE_PUSH_BUTTON"), role: .destructive) {
                    Task { await viewModel.forcePush() }
                }
            case .forcePullLatest:
                Button(ForkL10n.string("SYNC_FORCE_PULL_LATEST_BUTTON"), role: .destructive) {
                    Task { await viewModel.forcePull() }
                }
            case let .forcePullSnapshot(snapshot):
                Button(ForkL10n.string("SYNC_RESTORE_SNAPSHOT_BUTTON"), role: .destructive) {
                    Task { await viewModel.forcePull(snapshot: snapshot) }
                }
            case let .deleteSnapshot(snapshot):
                Button(NSLocalizedString("DELETE"), role: .destructive) {
                    Task { await viewModel.deleteRemoteSnapshot(snapshot) }
                }
            case .cleanupSnapshots:
                Button(ForkL10n.string("SYNC_CLEANUP_SNAPSHOTS_BUTTON"), role: .destructive) {
                    Task { await viewModel.cleanupRemoteSnapshots() }
                }
            case .resetCursor:
                Button(ForkL10n.string("SYNC_RESET_CURSOR_BUTTON"), role: .destructive) {
                    Task { await viewModel.resetLocalSyncState(clearCredentials: false) }
                }
            case .resetAll:
                Button(ForkL10n.string("SYNC_RESET_ALL_BUTTON"), role: .destructive) {
                    Task { await viewModel.resetLocalSyncState(clearCredentials: true) }
                }
        }
        Button(ForkL10n.string("SYNC_CANCEL_BUTTON"), role: .cancel) {}
    }
}
