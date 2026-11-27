//
//  SyncLogsView.swift
//  Aidoku
//

import SwiftUI
import UIKit

struct SyncLogsView: View {
    let logStore: SyncLogStore

    private enum LogFilter: String, CaseIterable, Identifiable {
        case all
        case info
        case warning
        case error

        var id: String { rawValue }

        var title: String {
            switch self {
                case .all:
                    ForkL10n.string("SYNC_LOGS_FILTER_ALL")
                case .info:
                    ForkL10n.string("SYNC_LOGS_FILTER_INFO")
                case .warning:
                    ForkL10n.string("SYNC_LOGS_FILTER_WARNING")
                case .error:
                    ForkL10n.string("SYNC_LOGS_FILTER_ERROR")
            }
        }

        func matches(_ entry: SyncLogEntry) -> Bool {
            switch self {
                case .all:
                    true
                case .info:
                    entry.level == .info
                case .warning:
                    entry.level == .warning
                case .error:
                    entry.level == .error
            }
        }
    }

    @State private var entries: [SyncLogEntry] = []
    @State private var selectedFilter: LogFilter = .all
    @State private var isLoading = false
    @State private var showClearConfirm = false
    @State private var shareItem: SyncShareItem?
    @State private var statusBanner: SyncBannerMessage?

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter
    }()

    private var filteredEntries: [SyncLogEntry] {
        entries.filter { selectedFilter.matches($0) }
    }

    var body: some View {
        List {
            if let statusBanner {
                Section {
                    SyncBannerView(banner: statusBanner)
                }
            }

            Section {
                Picker(ForkL10n.string("SYNC_LOGS_TITLE"), selection: $selectedFilter) {
                    ForEach(LogFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section {
                if isLoading && entries.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView()
                            .progressViewStyle(.circular)
                        Spacer()
                    }
                } else if filteredEntries.isEmpty {
                    Text(ForkL10n.string("SYNC_LOGS_EMPTY"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(filteredEntries) { entry in
                        logRow(entry)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(ForkL10n.string("SYNC_LOGS_TITLE"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task {
                        await copyAllLogs()
                    }
                } label: {
                    Label(ForkL10n.string("SYNC_LOGS_COPY_BUTTON"), systemImage: "doc.on.doc")
                }
                .disabled(entries.isEmpty)

                Button {
                    Task {
                        await exportLogs()
                    }
                } label: {
                    Label(ForkL10n.string("SYNC_LOGS_EXPORT_BUTTON"), systemImage: "square.and.arrow.up")
                }
                .disabled(entries.isEmpty)

                Button(role: .destructive) {
                    showClearConfirm = true
                } label: {
                    Label(ForkL10n.string("SYNC_LOGS_CLEAR_BUTTON"), systemImage: "trash")
                }
                .disabled(entries.isEmpty)
            }
        }
        .refreshable {
            await loadLogs()
        }
        .task {
            await loadLogs()
        }
        .onReceive(NotificationCenter.default.publisher(for: .forkSyncStateChanged)) { _ in
            Task {
                await loadLogs()
            }
        }
        .alert(
            ForkL10n.string("SYNC_LOGS_CLEAR_CONFIRM_TITLE"),
            isPresented: $showClearConfirm
        ) {
            Button(ForkL10n.string("SYNC_LOGS_CLEAR_BUTTON"), role: .destructive) {
                Task {
                    await clearLogs()
                }
            }
            Button(ForkL10n.string("SYNC_CANCEL_BUTTON"), role: .cancel) {}
        } message: {
            Text(ForkL10n.string("SYNC_LOGS_CLEAR_CONFIRM_MESSAGE"))
        }
        .sheet(item: $shareItem) { item in
            SyncShareSheet(items: item.items, cleanupURL: item.cleanupURL)
        }
    }

    private func logRow(_ entry: SyncLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.level.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color(for: entry.level))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(color(for: entry.level).opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                Text(entry.category)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

                Spacer()

                Text(Self.timestampFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func color(for level: SyncLogLevel) -> Color {
        switch level {
            case .info:
                .blue
            case .warning:
                .orange
            case .error:
                .red
        }
    }

    private func loadLogs() async {
        isLoading = true
        entries = await logStore.entries()
        isLoading = false
    }

    private func copyAllLogs() async {
        let text = await logStore.exportText()
        UIPasteboard.general.string = text
        statusBanner = SyncBannerMessage(tone: .success, text: ForkL10n.string("SYNC_LOGS_COPIED"))
    }

    private func exportLogs() async {
        let text = await logStore.exportText()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kodoku-sync-logs.txt")
        guard let data = text.data(using: .utf8) else { return }
        do {
            try data.write(to: url, options: .atomic)
            shareItem = SyncShareItem(items: [url], cleanupURL: url)
        } catch {
            UIPasteboard.general.string = text
            statusBanner = SyncBannerMessage(tone: .success, text: ForkL10n.string("SYNC_LOGS_COPIED"))
        }
    }

    private func clearLogs() async {
        await logStore.clear()
        entries = []
        statusBanner = nil
    }
}
