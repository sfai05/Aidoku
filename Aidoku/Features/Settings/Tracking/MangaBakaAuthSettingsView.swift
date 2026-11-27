//
//  MangaBakaAuthSettingsView.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import SwiftUI

struct MangaBakaAuthSettingsView: View {
    let initialOAuthExpired: Bool
    let onAuthChanged: () -> Void
    let onOAuthLogin: () -> Void
    let onLogout: () async -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var apiKeyInput = ""
    @State private var showApiKeyPlaintext = false
    @State private var isUsingApiKey = TrackerManager.mangabaka.isUsingApiKey
    @State private var isLoggedIn = TrackerManager.mangabaka.isLoggedIn
    @State private var cachedUsername = TrackerManager.mangabaka.authStore.cachedUsername
    @State private var isVerifying = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var infoMessage: String?
    @State private var scopeWarning: String?
    @State private var showLogoutConfirm = false
    @State private var safariUrl: URL?

    private let developerSettingsURL = URL(string: "https://mangabaka.org/my/settings/developer")!

    private var authMethodText: String {
        if isUsingApiKey {
            return ForkL10n.string("MANGABAKA_AUTH_METHOD_API_KEY")
        }
        if isLoggedIn {
            return ForkL10n.string("MANGABAKA_AUTH_METHOD_OAUTH")
        }
        return ForkL10n.string("MANGABAKA_AUTH_METHOD_SIGNED_OUT")
    }

    private var trimmedInput: String {
        apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        PlatformNavigationStack {
            List {
                statusSection
                patSection
                oauthSection
                if isLoggedIn {
                    logoutSection
                }
            }
            .navigationTitle(ForkL10n.string("MANGABAKA_AUTH_SHEET_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ForkL10n.string("MANGABAKA_AUTH_DONE")) {
                        dismiss()
                    }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { safariUrl != nil },
                    set: { isPresented in
                        if !isPresented {
                            safariUrl = nil
                        }
                    }
                )
            ) {
                SafariView(url: $safariUrl)
            }
            .alert(
                ForkL10n.string("MANGABAKA_AUTH_LOGOUT_CONFIRM_TITLE"),
                isPresented: $showLogoutConfirm
            ) {
                Button(NSLocalizedString("CANCEL"), role: .cancel) {}
                Button(NSLocalizedString("LOGOUT"), role: .destructive) {
                    Task {
                        await onLogout()
                        refreshLocalState()
                        dismiss()
                    }
                }
            } message: {
                Text(NSLocalizedString("TRACKER_LOGOUT_INFO"))
            }
        }
    }
}

private extension MangaBakaAuthSettingsView {
    var statusSection: some View {
        Section {
            HStack {
                Text(ForkL10n.string("MANGABAKA_AUTH_STATUS_LABEL"))
                Spacer()
                Text(authMethodText)
                    .foregroundStyle(isLoggedIn ? .primary : .secondary)
            }

            if isUsingApiKey, let cachedUsername, !cachedUsername.isEmpty {
                HStack {
                    Text(ForkL10n.string("MANGABAKA_AUTH_ACCOUNT_LABEL"))
                    Spacer()
                    Text(cachedUsername)
                        .foregroundStyle(.secondary)
                }
            }

            if !isUsingApiKey && initialOAuthExpired {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .padding(.top, 2)
                    Text(ForkL10n.string("MANGABAKA_AUTH_OAUTH_EXPIRED_HINT"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text(ForkL10n.string("MANGABAKA_AUTH_STATUS_SECTION"))
        }
    }

    var patSection: some View {
        let placeholder = ForkL10n.string(
            isUsingApiKey
                ? "MANGABAKA_AUTH_PAT_REPLACE_PLACEHOLDER"
                : "MANGABAKA_AUTH_PAT_PLACEHOLDER"
        )
        return Section {
            HStack(spacing: 8) {
                Group {
                    if showApiKeyPlaintext {
                        TextField(placeholder, text: $apiKeyInput)
                    } else {
                        SecureField(placeholder, text: $apiKeyInput)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.body.monospaced())

                Button {
                    showApiKeyPlaintext.toggle()
                } label: {
                    Image(systemName: showApiKeyPlaintext ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                Task {
                    await verifyAndSaveApiKey()
                }
            } label: {
                HStack {
                    Text(ForkL10n.string("MANGABAKA_AUTH_PAT_VERIFY_SAVE"))
                    if isVerifying {
                        Spacer()
                        ProgressView()
                    }
                }
            }
            .disabled(trimmedInput.isEmpty || isVerifying)

            if isUsingApiKey {
                Button(role: .destructive) {
                    TrackerManager.mangabaka.removeApiKey()
                    refreshLocalState()
                    errorMessage = nil
                    successMessage = nil
                    scopeWarning = nil
                    infoMessage = ForkL10n.string("MANGABAKA_AUTH_PAT_REMOVED")
                    onAuthChanged()
                } label: {
                    Text(ForkL10n.string("MANGABAKA_AUTH_PAT_REMOVE"))
                }
            }

            Button {
                safariUrl = developerSettingsURL
            } label: {
                Label(
                    ForkL10n.string("MANGABAKA_AUTH_PAT_OPEN_DEV"),
                    systemImage: "safari"
                )
            }

            if let errorMessage {
                statusBanner(text: errorMessage, systemImage: "xmark.octagon.fill", color: .red)
            }
            if let successMessage {
                statusBanner(text: successMessage, systemImage: "checkmark.circle.fill", color: .green)
            }
            if let infoMessage {
                statusBanner(text: infoMessage, systemImage: "info.circle.fill", color: .blue)
            }
            if let scopeWarning {
                statusBanner(text: scopeWarning, systemImage: "exclamationmark.triangle.fill", color: .orange)
            }
        } header: {
            Text(ForkL10n.string("MANGABAKA_AUTH_PAT_SECTION"))
        } footer: {
            Text(ForkL10n.string("MANGABAKA_AUTH_PAT_FOOTER"))
        }
    }

    var oauthSection: some View {
        Section {
            Button {
                onOAuthLogin()
            } label: {
                Text(
                    ForkL10n.string(
                        isLoggedIn && !isUsingApiKey
                            ? "MANGABAKA_AUTH_OAUTH_REFRESH"
                            : "MANGABAKA_AUTH_OAUTH_SIGN_IN"
                    )
                )
            }
        } header: {
            Text(ForkL10n.string("MANGABAKA_AUTH_OAUTH_SECTION"))
        } footer: {
            Text(ForkL10n.string("MANGABAKA_AUTH_OAUTH_FOOTER"))
        }
    }

    var logoutSection: some View {
        Section {
            Button(role: .destructive) {
                showLogoutConfirm = true
            } label: {
                Text(ForkL10n.string("MANGABAKA_AUTH_LOGOUT_BUTTON"))
            }
        }
    }

    func statusBanner(text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .padding(.top, 2)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    func verifyAndSaveApiKey() async {
        isVerifying = true
        errorMessage = nil
        successMessage = nil
        infoMessage = nil
        scopeWarning = nil
        defer { isVerifying = false }

        do {
            let profile = try await TrackerManager.mangabaka.saveApiKey(trimmedInput)
            refreshLocalState()
            successMessage = ForkL10n.format("MANGABAKA_AUTH_PAT_SUCCESS_FORMAT", profile.displayName)
            let missingScopes = profile.missingLibraryScopes
            if !missingScopes.isEmpty {
                scopeWarning = ForkL10n.format(
                    "MANGABAKA_AUTH_PAT_SCOPE_WARNING_FORMAT",
                    missingScopes.joined(separator: ", ")
                )
            }
            onAuthChanged()
        } catch {
            errorMessage = ForkL10n.format("MANGABAKA_AUTH_ERROR_INVALID_FORMAT", error.localizedDescription)
        }
    }

    func refreshLocalState() {
        isUsingApiKey = TrackerManager.mangabaka.isUsingApiKey
        isLoggedIn = TrackerManager.mangabaka.isLoggedIn
        cachedUsername = TrackerManager.mangabaka.authStore.cachedUsername
        apiKeyInput = ""
    }
}
