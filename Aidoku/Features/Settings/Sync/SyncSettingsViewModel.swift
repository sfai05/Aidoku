//
//  SyncSettingsViewModel.swift
//  Aidoku
//

import Combine
import Foundation

enum SyncBannerTone: Equatable {
    case success
    case info
    case warning
    case error
}

struct SyncBannerMessage: Equatable {
    let tone: SyncBannerTone
    let text: String
}

enum SyncTrafficLight: Equatable {
    case green
    case yellow
    case red
    case gray
}

@MainActor
final class SyncSettingsViewModel: ObservableObject {
    let engine: SyncEngine
    let logStore: SyncLogStore
    private let notificationCenter: NotificationCenter
    private var stateObserver: AnyCancellable?

    @Published private(set) var status: SyncStatusSnapshot
    @Published private(set) var signedInEmail: String?
    @Published var isEnabled: Bool

    @Published var serverURLInput: String
    @Published var collectionNameInput: String
    @Published var deviceNameInput: String

    @Published var autoSyncOnForeground: Bool
    @Published var includeSettings: Bool
    @Published var maxRemoteSnapshots: Int
    @Published var autoSyncDebounceSeconds: Int

    @Published var emailInput: String
    @Published var passwordInput: String = ""

    @Published private(set) var healthStatus: SyncHealthStatus?
    @Published private(set) var isCheckingHealth = false
    @Published private(set) var isAuthenticating = false
    @Published private(set) var isRunningAction = false
    @Published private(set) var isLoadingSnapshots = false
    @Published private(set) var remoteSnapshots: [SyncSnapshotMetadata] = []
    @Published var bannerMessage: SyncBannerMessage?

    init(
        engine: SyncEngine = .shared,
        logStore: SyncLogStore = .shared,
        notificationCenter: NotificationCenter = .default
    ) {
        self.engine = engine
        self.logStore = logStore
        self.notificationCenter = notificationCenter

        let config = engine.configuration
        config.ensureDefaultDeviceName()

        let session = engine.pocketBaseProvider?.currentSession()
        self.signedInEmail = session.map { $0.email.isEmpty ? $0.userId : $0.email }
        self.isEnabled = config.isEnabled
        self.serverURLInput = config.serverURL ?? ""
        self.collectionNameInput = config.collectionName
        self.deviceNameInput = config.deviceName
        self.autoSyncOnForeground = config.autoSyncOnForeground
        self.includeSettings = config.includeSettings
        self.maxRemoteSnapshots = config.maxRemoteSnapshots
        self.autoSyncDebounceSeconds = Int(config.autoSyncDebounceSeconds)
        self.emailInput = session?.email ?? ""
        self.status = SyncStatusSnapshot(
            indicator: config.isEnabled ? .synced : .disabled,
            serverURL: config.serverURL,
            lastSyncedAt: config.lastSyncedAt,
            lastSyncedRevision: config.lastSyncedRevision,
            hasPendingChanges: false,
            lastErrorMessage: nil,
            stats: config.lastSyncedStats
        )

        self.stateObserver = notificationCenter.publisher(for: .forkSyncStateChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor [weak self] in
                    await self?.refreshState()
                }
            }
    }

    var trafficLight: SyncTrafficLight {
        switch status.indicator {
            case .synced:
                .green
            case .syncing, .pendingChanges:
                .yellow
            case .error:
                .red
            case .disabled:
                .gray
        }
    }

    var statusTitle: String {
        switch status.indicator {
            case .synced:
                ForkL10n.string("SYNC_STATUS_SYNCED")
            case .syncing:
                ForkL10n.string("SYNC_STATUS_SYNCING")
            case .pendingChanges:
                ForkL10n.string("SYNC_STATUS_PENDING")
            case .error:
                ForkL10n.string("SYNC_STATUS_ERROR")
            case .disabled:
                ForkL10n.string("SYNC_STATUS_DISABLED")
        }
    }

    var isSignedIn: Bool {
        signedInEmail != nil
    }

    var isBusy: Bool {
        isAuthenticating || isRunningAction || status.indicator == .syncing
    }

    var effectiveCollectionName: String {
        let trimmed = collectionNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return PocketBaseSchema.isValidCollectionName(trimmed) ? trimmed : PocketBaseSchema.defaultCollectionName
    }

    var isInsecureRemoteHTTPURL: Bool {
        Self.isInsecureRemoteHTTPURL(serverURLInput)
    }

    func refreshState() async {
        status = await engine.currentStatus()
        let config = engine.configuration
        isEnabled = config.isEnabled
        if let session = engine.pocketBaseProvider?.currentSession() {
            signedInEmail = session.email.isEmpty ? session.userId : session.email
        } else {
            signedInEmail = nil
        }
        autoSyncOnForeground = config.autoSyncOnForeground
        includeSettings = config.includeSettings
        maxRemoteSnapshots = config.maxRemoteSnapshots
        autoSyncDebounceSeconds = Int(config.autoSyncDebounceSeconds)
    }

    @discardableResult
    func saveConnectionSettings(requireServerURL: Bool = true, showBanner: Bool = true) -> Bool {
        do {
            let normalizedServer = try validatedServerURLString(requireNonEmpty: requireServerURL)
            let validCollection = try validatedCollectionName()

            engine.configuration.serverURL = normalizedServer
            engine.configuration.collectionName = validCollection
            serverURLInput = normalizedServer ?? ""
            collectionNameInput = validCollection

            if showBanner {
                bannerMessage = SyncBannerMessage(tone: .success, text: ForkL10n.string("SYNC_SETTINGS_SAVED"))
            }
            Task {
                await engine.notifyConfigurationChanged()
            }
            return true
        } catch {
            bannerMessage = SyncBannerMessage(tone: .error, text: error.localizedDescription)
            return false
        }
    }

    func persistDeviceNameInput() {
        let trimmed = deviceNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.configuration.deviceName = trimmed.isEmpty ? "Kodoku Device" : deviceNameInput
    }

    func updateDeviceName() {
        let trimmed = deviceNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? "Kodoku Device" : trimmed
        deviceNameInput = resolved
        engine.configuration.deviceName = resolved
    }

    func updateSyncOptions() {
        let config = engine.configuration
        config.autoSyncOnForeground = autoSyncOnForeground
        config.includeSettings = includeSettings
        config.maxRemoteSnapshots = maxRemoteSnapshots
        config.autoSyncDebounceSeconds = TimeInterval(autoSyncDebounceSeconds)
        maxRemoteSnapshots = config.maxRemoteSnapshots
        autoSyncDebounceSeconds = Int(config.autoSyncDebounceSeconds)
    }

    func setEnabled(_ enabled: Bool) async {
        if enabled {
            let trimmedInput = serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedInput.isEmpty {
                guard saveConnectionSettings(requireServerURL: true, showBanner: false) else {
                    isEnabled = false
                    return
                }
            }
            let hasValidServer = (try? engine.configuration.normalizedServerURL()) != nil
            let hasSession = engine.pocketBaseProvider == nil || isSignedIn
            guard hasValidServer, hasSession else {
                isEnabled = false
                await engine.setEnabled(false)
                bannerMessage = SyncBannerMessage(
                    tone: .error,
                    text: ForkL10n.string("SYNC_ENABLE_REQUIREMENT_ERROR")
                )
                await refreshState()
                return
            }
        }

        isEnabled = enabled
        await engine.setEnabled(enabled)
        await refreshState()
    }

    func signIn() async {
        let capturedPassword = passwordInput
        passwordInput = ""

        guard saveConnectionSettings(requireServerURL: true, showBanner: false) else {
            return
        }
        guard let normalizedURL = try? engine.configuration.normalizedServerURL().absoluteString else {
            return
        }

        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let session = try await engine.signIn(
                serverURL: normalizedURL,
                email: emailInput,
                password: capturedPassword
            )
            emailInput = session.email
            await refreshState()
            bannerMessage = SyncBannerMessage(tone: .success, text: ForkL10n.string("SYNC_SIGN_IN_SUCCESS"))
            await runHealthCheck()
        } catch {
            await refreshState()
            bannerMessage = SyncBannerMessage(tone: .error, text: error.localizedDescription)
        }
    }

    func signOut() async {
        isAuthenticating = true
        defer { isAuthenticating = false }

        passwordInput = ""
        await engine.signOut()
        healthStatus = nil
        remoteSnapshots = []
        bannerMessage = nil
        await refreshState()
    }

    func refreshSession() async {
        guard let provider = engine.pocketBaseProvider else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            let session = try await provider.refreshAuth()
            emailInput = session.email
            await refreshState()
            bannerMessage = SyncBannerMessage(tone: .success, text: ForkL10n.string("SYNC_SESSION_REFRESHED"))
        } catch {
            await refreshState()
            bannerMessage = SyncBannerMessage(tone: .error, text: error.localizedDescription)
        }
    }

    func syncNow() async {
        isRunningAction = true
        defer { isRunningAction = false }

        do {
            let result = try await engine.syncNow()
            await refreshState()
            bannerMessage = SyncBannerMessage(
                tone: .success,
                text: formattedSyncResult(result)
            )
        } catch {
            await refreshState()
            bannerMessage = SyncBannerMessage(tone: .error, text: error.localizedDescription)
        }
    }

    func runHealthCheck() async {
        if !serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard saveConnectionSettings(requireServerURL: true, showBanner: false) else {
                return
            }
        }

        isCheckingHealth = true
        defer { isCheckingHealth = false }

        let result = await engine.checkHealth()
        healthStatus = result
        await refreshState()
    }

    func provisionCollection(
        superuserEmail: String,
        superuserPassword: String
    ) async throws -> PocketBaseProvisionResult {
        guard let serverURL = try validatedServerURLString(requireNonEmpty: true) else {
            throw SyncError.notConfigured("PocketBase server URL is missing.")
        }
        let collection = try validatedCollectionName()
        guard let provider = engine.pocketBaseProvider else {
            throw SyncError.notConfigured("PocketBase provider is unavailable.")
        }

        engine.configuration.serverURL = serverURL
        engine.configuration.collectionName = collection
        serverURLInput = serverURL
        collectionNameInput = collection

        let result = try await provider.provisionCollection(
            serverURL: serverURL,
            collectionName: collection,
            superuserEmail: superuserEmail,
            superuserPassword: superuserPassword
        )
        if isSignedIn {
            await runHealthCheck()
        } else {
            await refreshState()
        }
        return result
    }

    func exportSchemaJSON() -> String {
        let collection = effectiveCollectionName
        if let json = try? PocketBaseSchema.exportSchemaJSON(collectionName: collection) {
            return json
        }
        return (try? PocketBaseSchema.exportSchemaJSON()) ?? "[]"
    }
}

// MARK: - Recovery & Snapshot Management

extension SyncSettingsViewModel {
    func loadRemoteSnapshots() async {
        isLoadingSnapshots = true
        defer { isLoadingSnapshots = false }

        do {
            remoteSnapshots = try await engine.listRemoteSnapshots(limit: 25)
        } catch {
            bannerMessage = SyncBannerMessage(tone: .error, text: error.localizedDescription)
        }
    }

    func forcePush() async {
        isRunningAction = true
        defer { isRunningAction = false }

        do {
            let result = try await engine.forcePush()
            await refreshState()
            bannerMessage = SyncBannerMessage(tone: .success, text: formattedSyncResult(result))
        } catch {
            await refreshState()
            bannerMessage = SyncBannerMessage(tone: .error, text: error.localizedDescription)
        }
    }

    func forcePull(snapshot: SyncSnapshotMetadata? = nil) async {
        isRunningAction = true
        defer { isRunningAction = false }

        do {
            let result = try await engine.forcePull(recordId: snapshot?.id, publishAsNewRevision: true)
            await refreshState()
            bannerMessage = SyncBannerMessage(tone: .success, text: formattedSyncResult(result))
        } catch {
            await refreshState()
            bannerMessage = SyncBannerMessage(tone: .error, text: error.localizedDescription)
        }
    }

    func cleanupRemoteSnapshots() async {
        isRunningAction = true
        defer { isRunningAction = false }

        do {
            let deletedCount = try await engine.cleanupRemoteSnapshots(keepLatest: engine.configuration.maxRemoteSnapshots)
            bannerMessage = SyncBannerMessage(
                tone: .info,
                text: ForkL10n.format("SYNC_CLEANUP_RESULT_FORMAT", deletedCount)
            )
            await loadRemoteSnapshots()
        } catch {
            bannerMessage = SyncBannerMessage(tone: .error, text: error.localizedDescription)
        }
    }

    func deleteRemoteSnapshot(_ snapshot: SyncSnapshotMetadata) async {
        isRunningAction = true
        defer { isRunningAction = false }

        do {
            try await engine.deleteRemoteSnapshot(id: snapshot.id)
            remoteSnapshots.removeAll { $0.id == snapshot.id }
            bannerMessage = SyncBannerMessage(
                tone: .info,
                text: ForkL10n.format("SYNC_DELETE_SNAPSHOT_SUCCESS_FORMAT", snapshot.revision)
            )
        } catch {
            bannerMessage = SyncBannerMessage(tone: .error, text: error.localizedDescription)
        }
    }

    func resetLocalSyncState(clearCredentials: Bool) async {
        isRunningAction = true
        defer { isRunningAction = false }

        await engine.resetLocalSyncState(clearCredentials: clearCredentials)
        if clearCredentials {
            healthStatus = nil
            remoteSnapshots = []
            passwordInput = ""
        }
        await refreshState()
        bannerMessage = SyncBannerMessage(
            tone: .info,
            text: ForkL10n.string(clearCredentials ? "SYNC_RESET_ALL_DONE" : "SYNC_RESET_CURSOR_DONE")
        )
    }
}

// MARK: - Helpers

extension SyncSettingsViewModel {
    static func isInsecureRemoteHTTPURL(_ rawURL: String) -> Bool {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = try? SyncConfiguration.normalizeServerURL(trimmed) else {
            return false
        }
        guard url.scheme?.lowercased() == "http", let host = url.host?.lowercased() else {
            return false
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") {
            return false
        }
        if isPrivateRFC1918IPv4(host) {
            return false
        }
        return true
    }

    private static func isPrivateRFC1918IPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        if octets[0] == 10 {
            return true
        }
        if octets[0] == 192 && octets[1] == 168 {
            return true
        }
        if octets[0] == 172 && (16...31).contains(octets[1]) {
            return true
        }
        return false
    }

    private func validatedServerURLString(requireNonEmpty: Bool) throws -> String? {
        let trimmed = serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if requireNonEmpty {
                throw SyncError.notConfigured("PocketBase server URL is missing.")
            }
            return nil
        }
        return try SyncConfiguration.normalizeServerURL(trimmed).absoluteString
    }

    private func validatedCollectionName() throws -> String {
        let trimmed = collectionNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? PocketBaseSchema.defaultCollectionName : trimmed
        guard PocketBaseSchema.isValidCollectionName(candidate) else {
            throw SyncError.notConfigured(ForkL10n.string("SYNC_INVALID_COLLECTION_ERROR"))
        }
        return candidate
    }

    private func formattedSyncResult(_ result: SyncResult) -> String {
        let actionText: String = switch result.action {
            case .upToDate:
                ForkL10n.string("SYNC_ACTION_UP_TO_DATE")
            case .pulled:
                ForkL10n.string("SYNC_ACTION_PULLED")
            case .pushed:
                ForkL10n.string("SYNC_ACTION_PUSHED")
            case .merged:
                ForkL10n.string("SYNC_ACTION_MERGED")
            case .forcePushed:
                ForkL10n.string("SYNC_ACTION_FORCE_PUSHED")
            case .forcePulled:
                ForkL10n.string("SYNC_ACTION_FORCE_PULLED")
        }
        return ForkL10n.format("SYNC_RESULT_FORMAT", actionText, result.revision)
    }
}
