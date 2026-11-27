//
//  SyncSetupWizardSheet.swift
//  Aidoku
//

import SwiftUI
import UIKit

struct SyncShareItem: Identifiable {
    let id = UUID()
    let items: [Any]
    let cleanupURL: URL?

    init(items: [Any], cleanupURL: URL? = nil) {
        self.items = items
        self.cleanupURL = cleanupURL
    }
}

struct SyncShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    let cleanupURL: URL?

    init(items: [Any], cleanupURL: URL? = nil) {
        self.items = items
        self.cleanupURL = cleanupURL
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let cleanupURL {
            controller.completionWithItemsHandler = { _, _, _, _ in
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

struct SyncBannerView: View {
    let banner: SyncBannerMessage

    private var accentColor: Color {
        switch banner.tone {
            case .success:
                .green
            case .info:
                .blue
            case .warning:
                .orange
            case .error:
                .red
        }
    }

    private var iconName: String {
        switch banner.tone {
            case .success:
                "checkmark.circle.fill"
            case .info:
                "info.circle.fill"
            case .warning:
                "exclamationmark.triangle.fill"
            case .error:
                "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(accentColor)
                .padding(.top, 1)
            Text(banner.text)
                .font(.footnote)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}

struct SyncSetupWizardSheet: View {
    @ObservedObject var viewModel: SyncSettingsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var superuserEmail = ""
    @State private var superuserPassword = ""
    @State private var isProvisioning = false
    @State private var provisionResult: PocketBaseProvisionResult?
    @State private var errorMessage: String?

    var body: some View {
        PlatformNavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundStyle(.blue)
                            .padding(.top, 2)
                        Text(ForkL10n.string("SYNC_WIZARD_DESCRIPTION"))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section(ForkL10n.string("SYNC_WIZARD_TARGET_SECTION")) {
                    row(
                        title: ForkL10n.string("SYNC_SERVER_URL_LABEL"),
                        value: viewModel.serverURLInput.isEmpty
                            ? ForkL10n.string("SYNC_NOT_CONFIGURED")
                            : viewModel.serverURLInput
                    )
                    row(
                        title: ForkL10n.string("SYNC_COLLECTION_NAME_LABEL"),
                        value: viewModel.effectiveCollectionName
                    )
                }

                Section(ForkL10n.string("SYNC_WIZARD_SUPERUSER_SECTION")) {
                    TextField(ForkL10n.string("SYNC_EMAIL_LABEL"), text: $superuserEmail)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(ForkL10n.string("SYNC_PASSWORD_LABEL"), text: $superuserPassword)
                }

                Section {
                    Button {
                        Task {
                            await runProvisioning()
                        }
                    } label: {
                        HStack {
                            Text(ForkL10n.string("SYNC_WIZARD_CREATE_BUTTON"))
                            Spacer()
                            if isProvisioning {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            }
                        }
                    }
                    .disabled(
                        isProvisioning
                            || viewModel.serverURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || superuserEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || superuserPassword.isEmpty
                    )
                }

                if let provisionResult {
                    Section {
                        provisionResultView(provisionResult)
                    }
                } else if let errorMessage {
                    Section {
                        SyncBannerView(banner: SyncBannerMessage(tone: .error, text: errorMessage))
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(ForkL10n.string("SYNC_SETUP_WIZARD_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ForkL10n.string("SYNC_DONE_BUTTON")) {
                        clearTransientCredentials()
                        dismiss()
                    }
                }
            }
            .onDisappear {
                clearTransientCredentials()
            }
        }
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    @ViewBuilder
    private func provisionResultView(_ result: PocketBaseProvisionResult) -> some View {
        switch result {
            case let .created(collectionName):
                SyncBannerView(banner: SyncBannerMessage(
                    tone: .success,
                    text: ForkL10n.format("SYNC_WIZARD_CREATED_FORMAT", collectionName)
                ))
            case let .alreadyExists(collectionName, missingFields, configurationIssues):
                if missingFields.isEmpty && configurationIssues.isEmpty {
                    SyncBannerView(banner: SyncBannerMessage(
                        tone: .success,
                        text: ForkL10n.format("SYNC_WIZARD_READY_FORMAT", collectionName)
                    ))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        SyncBannerView(banner: SyncBannerMessage(
                            tone: .warning,
                            text: ForkL10n.format("SYNC_WIZARD_ISSUES_HEADER_FORMAT", collectionName)
                        ))
                        ForEach(missingFields, id: \.self) { field in
                            Text("• \(ForkL10n.format("SYNC_WIZARD_MISSING_FIELD_FORMAT", field))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(configurationIssues, id: \.self) { issue in
                            Text("• \(issue)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
        }
    }

    private func runProvisioning() async {
        let capturedEmail = superuserEmail
        let capturedPassword = superuserPassword
        clearTransientCredentials()

        isProvisioning = true
        provisionResult = nil
        errorMessage = nil
        defer {
            isProvisioning = false
            clearTransientCredentials()
        }

        do {
            provisionResult = try await viewModel.provisionCollection(
                superuserEmail: capturedEmail,
                superuserPassword: capturedPassword
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearTransientCredentials() {
        superuserEmail = ""
        superuserPassword = ""
    }
}

struct SyncSchemaImportSheet: View {
    let schemaJSON: String
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false
    @State private var shareItem: SyncShareItem?

    var body: some View {
        PlatformNavigationStack {
            List {
                Section(ForkL10n.string("SYNC_SCHEMA_STEPS_SECTION")) {
                    Text(ForkL10n.string("SYNC_SCHEMA_STEPS_BODY"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                }

                Section {
                    Button {
                        UIPasteboard.general.string = schemaJSON
                        copied = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copied = false
                        }
                    } label: {
                        HStack {
                            Label(
                                ForkL10n.string(copied ? "SYNC_COPIED_FEEDBACK" : "SYNC_COPY_JSON_BUTTON"),
                                systemImage: copied ? "checkmark" : "doc.on.doc"
                            )
                            Spacer()
                        }
                    }

                    Button {
                        exportSchemaFile()
                    } label: {
                        Label(ForkL10n.string("SYNC_EXPORT_SCHEMA_BUTTON"), systemImage: "square.and.arrow.up")
                    }
                }

                Section(ForkL10n.string("SYNC_SCHEMA_PREVIEW_SECTION")) {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(schemaJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(ForkL10n.string("SYNC_MANUAL_SCHEMA_TITLE"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(ForkL10n.string("SYNC_DONE_BUTTON")) {
                        dismiss()
                    }
                }
            }
            .sheet(item: $shareItem) { item in
                SyncShareSheet(items: item.items, cleanupURL: item.cleanupURL)
            }
        }
    }

    private func exportSchemaFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pb_schema.json")
        guard let data = schemaJSON.data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: .atomic)
            shareItem = SyncShareItem(items: [url], cleanupURL: url)
        } catch {
            UIPasteboard.general.string = schemaJSON
            copied = true
        }
    }
}
