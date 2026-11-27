//
//  SyncSettingsView.swift
//  Aidoku
//

import SwiftUI

struct SyncSettingsView: View {
    @StateObject private var viewModel = SyncSettingsViewModel()

    @State private var showSetupWizard = false
    @State private var showSchemaSheet = false
    @State private var showSignOutConfirm = false

    private static let syncDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let statsColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        List {
            statusSection
            connectionSection
            healthAndSetupSection
            optionsSection
            diagnosticsSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(ForkL10n.string("SYNC_TITLE"))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.refreshState()
        }
        .sheet(isPresented: $showSetupWizard) {
            SyncSetupWizardSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $showSchemaSheet) {
            SyncSchemaImportSheet(schemaJSON: viewModel.exportSchemaJSON())
        }
        .alert(
            ForkL10n.string("SYNC_SIGN_OUT_CONFIRM_TITLE"),
            isPresented: $showSignOutConfirm
        ) {
            Button(ForkL10n.string("SYNC_SIGN_OUT_BUTTON"), role: .destructive) {
                Task {
                    await viewModel.signOut()
                }
            }
            Button(ForkL10n.string("SYNC_CANCEL_BUTTON"), role: .cancel) {}
        } message: {
            Text(ForkL10n.string("SYNC_SIGN_OUT_CONFIRM_MESSAGE"))
        }
    }

    // MARK: - Sections

    private var statusSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: statusIconName)
                    .font(.title3)
                    .foregroundStyle(statusColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.statusTitle)
                        .font(.headline)
                    if let server = viewModel.status.serverURL, !server.isEmpty {
                        Text(server)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if viewModel.status.indicator == .syncing || viewModel.isRunningAction {
                    ProgressView()
                        .progressViewStyle(.circular)
                }
            }
            .padding(.vertical, 2)

            if let banner = viewModel.bannerMessage {
                SyncBannerView(banner: banner)
            } else if let errorMessage = viewModel.status.lastErrorMessage, viewModel.status.indicator == .error {
                SyncBannerView(banner: SyncBannerMessage(tone: .error, text: errorMessage))
            }

            Toggle(
                ForkL10n.string("SYNC_ENABLE_TOGGLE"),
                isOn: Binding(
                    get: { viewModel.isEnabled },
                    set: { newValue in
                        Task {
                            await viewModel.setEnabled(newValue)
                        }
                    }
                )
            )
            .disabled(viewModel.isBusy)

            keyValueRow(
                title: ForkL10n.string("SYNC_SERVER_LABEL"),
                value: {
                    if let server = viewModel.status.serverURL, !server.isEmpty {
                        return server
                    }
                    return ForkL10n.string("SYNC_NOT_CONFIGURED")
                }()
            )
            keyValueRow(
                title: ForkL10n.string("SYNC_ACCOUNT_LABEL"),
                value: viewModel.signedInEmail ?? ForkL10n.string("SYNC_NOT_SIGNED_IN")
            )
            keyValueRow(
                title: ForkL10n.string("SYNC_LAST_SYNCED_LABEL"),
                value: formattedLastSyncedDate
            )
            keyValueRow(
                title: ForkL10n.string("SYNC_REVISION_LABEL"),
                value: viewModel.status.lastSyncedRevision > 0
                    ? "#\(viewModel.status.lastSyncedRevision)"
                    : "—"
            )

            LazyVGrid(columns: statsColumns, spacing: 8) {
                statTile(title: ForkL10n.string("SYNC_STATS_LIBRARY"), value: viewModel.status.stats.libraryCount)
                statTile(title: ForkL10n.string("SYNC_STATS_HISTORY"), value: viewModel.status.stats.historyCount)
                statTile(title: ForkL10n.string("SYNC_STATS_CATEGORIES"), value: viewModel.status.stats.categoryCount)
                statTile(title: ForkL10n.string("SYNC_STATS_TRACKERS"), value: viewModel.status.stats.trackCount)
                statTile(title: ForkL10n.string("SYNC_STATS_SESSIONS"), value: viewModel.status.stats.readingSessionCount)
            }
            .padding(.vertical, 4)

            Button {
                Task {
                    await viewModel.syncNow()
                }
            } label: {
                Label(ForkL10n.string("SYNC_NOW_BUTTON"), systemImage: "arrow.clockwise")
            }
            .disabled(!viewModel.isEnabled || !viewModel.isSignedIn || viewModel.isBusy)
        } header: {
            Text(ForkL10n.string("SYNC_SECTION_STATUS"))
        } footer: {
            Text(ForkL10n.string("SYNC_ENABLE_FOOTER"))
        }
    }

    private var connectionSection: some View {
        Section {
            HStack {
                Text(ForkL10n.string("SYNC_SERVER_URL_LABEL"))
                Spacer()
                TextField(ForkL10n.string("SYNC_SERVER_URL_PLACEHOLDER"), text: $viewModel.serverURLInput)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        Task {
                            await viewModel.saveConnectionSettings()
                        }
                    }
            }

            if viewModel.isInsecureRemoteHTTPURL {
                SyncBannerView(banner: SyncBannerMessage(
                    tone: .warning,
                    text: ForkL10n.string("SYNC_HTTPS_WARNING")
                ))
            }

            HStack {
                Text(ForkL10n.string("SYNC_COLLECTION_NAME_LABEL"))
                Spacer()
                TextField(PocketBaseSchema.defaultCollectionName, text: $viewModel.collectionNameInput)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit {
                        Task {
                            await viewModel.saveConnectionSettings(
                                requireServerURL: !viewModel.serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            )
                        }
                    }
            }

            Button {
                Task {
                    await viewModel.saveConnectionSettings(
                        requireServerURL: !viewModel.serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            } label: {
                Text(ForkL10n.string("SYNC_SAVE_SETTINGS_BUTTON"))
            }
            .disabled(viewModel.isBusy)

            if let email = viewModel.signedInEmail {
                keyValueRow(title: ForkL10n.string("SYNC_EMAIL_LABEL"), value: email)

                Button {
                    Task {
                        await viewModel.refreshSession()
                    }
                } label: {
                    HStack {
                        Text(ForkL10n.string("SYNC_REFRESH_SESSION_BUTTON"))
                        Spacer()
                        if viewModel.isAuthenticating {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                }
                .disabled(viewModel.isBusy)

                Button(role: .destructive) {
                    showSignOutConfirm = true
                } label: {
                    Text(ForkL10n.string("SYNC_SIGN_OUT_BUTTON"))
                }
                .disabled(viewModel.isBusy)
            } else {
                TextField(ForkL10n.string("SYNC_EMAIL_LABEL"), text: $viewModel.emailInput)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                SecureField(ForkL10n.string("SYNC_PASSWORD_LABEL"), text: $viewModel.passwordInput)

                Button {
                    Task {
                        await viewModel.signIn()
                    }
                } label: {
                    HStack {
                        Text(ForkL10n.string("SYNC_SIGN_IN_BUTTON"))
                        Spacer()
                        if viewModel.isAuthenticating {
                            ProgressView()
                                .progressViewStyle(.circular)
                        }
                    }
                }
                .disabled(
                    viewModel.isBusy
                        || viewModel.serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || viewModel.emailInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || viewModel.passwordInput.isEmpty
                )
            }
        } header: {
            Text(ForkL10n.string("SYNC_SECTION_CONNECTION"))
        } footer: {
            Text(ForkL10n.string("SYNC_CONNECTION_FOOTER"))
        }
    }

    private var healthAndSetupSection: some View {
        Section(ForkL10n.string("SYNC_SECTION_HEALTH")) {
            Button {
                Task {
                    await viewModel.runHealthCheck()
                }
            } label: {
                HStack {
                    Label(ForkL10n.string("SYNC_CHECK_HEALTH_BUTTON"), systemImage: "checkmark.shield")
                    Spacer()
                    if viewModel.isCheckingHealth {
                        ProgressView()
                            .progressViewStyle(.circular)
                    }
                }
            }
            .disabled(viewModel.isCheckingHealth || viewModel.serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let health = viewModel.healthStatus {
                healthRow(title: ForkL10n.string("SYNC_HEALTH_REACHABLE"), passed: health.isReachable)
                healthRow(title: ForkL10n.string("SYNC_HEALTH_AUTH"), passed: health.isAuthenticated)
                healthRow(title: ForkL10n.string("SYNC_HEALTH_COLLECTION"), passed: health.collectionReady)
                if !health.message.isEmpty {
                    SyncBannerView(banner: SyncBannerMessage(
                        tone: health.isHealthy ? .success : .warning,
                        text: health.message
                    ))
                }
            }

            Button {
                showSetupWizard = true
            } label: {
                Label(ForkL10n.string("SYNC_SETUP_WIZARD_TITLE"), systemImage: "wand.and.stars")
            }

            Button {
                showSchemaSheet = true
            } label: {
                Label(ForkL10n.string("SYNC_MANUAL_SCHEMA_TITLE"), systemImage: "doc.text")
            }
        }
    }

    private var optionsSection: some View {
        Section {
            HStack {
                Text(ForkL10n.string("SYNC_DEVICE_NAME_LABEL"))
                Spacer()
                TextField("Kodoku Device", text: $viewModel.deviceNameInput)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: viewModel.deviceNameInput) { _ in
                        viewModel.persistDeviceNameInput()
                    }
                    .onSubmit {
                        viewModel.updateDeviceName()
                    }
            }

            Toggle(ForkL10n.string("SYNC_AUTO_FOREGROUND_TOGGLE"), isOn: $viewModel.autoSyncOnForeground)
                .onChange(of: viewModel.autoSyncOnForeground) { _ in
                    viewModel.updateSyncOptions()
                }

            Toggle(ForkL10n.string("SYNC_INCLUDE_SETTINGS_TOGGLE"), isOn: $viewModel.includeSettings)
                .onChange(of: viewModel.includeSettings) { _ in
                    viewModel.updateSyncOptions()
                }

            Stepper(
                ForkL10n.format("SYNC_RETENTION_FORMAT", viewModel.maxRemoteSnapshots),
                value: $viewModel.maxRemoteSnapshots,
                in: 2...50
            )
            .onChange(of: viewModel.maxRemoteSnapshots) { _ in
                viewModel.updateSyncOptions()
            }

            Picker(ForkL10n.string("SYNC_DEBOUNCE_LABEL"), selection: $viewModel.autoSyncDebounceSeconds) {
                ForEach([5, 15, 30, 60], id: \.self) { seconds in
                    Text(ForkL10n.format("SYNC_SECONDS_FORMAT", seconds)).tag(seconds)
                }
            }
            .onChange(of: viewModel.autoSyncDebounceSeconds) { _ in
                viewModel.updateSyncOptions()
            }
        } header: {
            Text(ForkL10n.string("SYNC_SECTION_OPTIONS"))
        } footer: {
            Text(ForkL10n.string("SYNC_OPTIONS_FOOTER"))
        }
    }

    private var diagnosticsSection: some View {
        Section(ForkL10n.string("SYNC_SECTION_DIAGNOSTICS")) {
            NavigationLink(destination: SyncLogsView(logStore: viewModel.logStore)) {
                Label(ForkL10n.string("SYNC_LOGS_TITLE"), systemImage: "doc.plaintext")
            }

            NavigationLink(destination: SyncRecoveryView(viewModel: viewModel)) {
                Label(ForkL10n.string("SYNC_RECOVERY_TITLE"), systemImage: "wrench.and.screwdriver")
            }
        }
    }

    // MARK: - Subviews & Formatting

    private var statusColor: Color {
        switch viewModel.trafficLight {
            case .green:
                .green
            case .yellow:
                .orange
            case .red:
                .red
            case .gray:
                .secondary
        }
    }

    private var statusIconName: String {
        switch viewModel.trafficLight {
            case .green:
                "checkmark.circle.fill"
            case .yellow:
                viewModel.status.indicator == .syncing ? "arrow.clockwise.icloud.fill" : "clock.fill"
            case .red:
                "exclamationmark.triangle.fill"
            case .gray:
                "pause.circle.fill"
        }
    }

    private var formattedLastSyncedDate: String {
        guard let date = viewModel.status.lastSyncedAt else {
            return ForkL10n.string("SYNC_NEVER")
        }
        return Self.syncDateFormatter.string(from: date)
    }

    private func keyValueRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func healthRow(title: String, passed: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(passed ? .green : .red)
        }
    }

    private func statTile(title: String, value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.headline)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .background(Color(uiColor: .systemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
