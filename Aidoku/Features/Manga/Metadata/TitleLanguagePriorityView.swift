//
//  TitleLanguagePriorityView.swift
//  Aidoku
//
//  Created by Kodoku on 11/27/26.
//

import SwiftUI

struct TitleLanguagePriorityView: View {
    private let store: TitleLanguagePriorityStore

    @State private var languages: [String]
    @State private var editMode: EditMode = .active

    init(store: TitleLanguagePriorityStore = .shared) {
        self.store = store
        self._languages = State(initialValue: store.priorityOrder)
    }

    private var availableToAdd: [TitleLanguagePriorityStore.LanguageInfo] {
        let activeLowered = Set(languages.map { $0.lowercased() })
        return TitleLanguagePriorityStore.catalog.filter { !activeLowered.contains($0.code.lowercased()) }
    }

    var body: some View {
        List {
            Section {
                ForEach(languages, id: \.self) { code in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(TitleLanguagePriorityStore.displayName(for: code))
                                .font(.body)
                                .foregroundStyle(.primary)
                            Text(code)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(TitleLanguagePriorityStore.shortLabel(for: code))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color(uiColor: .secondarySystemFill))
                            .clipShape(Capsule())
                    }
                    .deleteDisabled(languages.count <= 1)
                }
                .onMove { source, destination in
                    languages.move(fromOffsets: source, toOffset: destination)
                    persistChanges()
                }
                .onDelete { offsets in
                    guard languages.count > offsets.count else { return }
                    languages.remove(atOffsets: offsets)
                    persistChanges()
                }
            } header: {
                Text(ForkL10n.string("METADATA_PRIORITY_ORDER_SECTION"))
            } footer: {
                Text(ForkL10n.string("METADATA_TITLE_LANGUAGE_PRIORITY_FOOTER"))
            }

            if !availableToAdd.isEmpty {
                Section(ForkL10n.string("METADATA_PRIORITY_ADD_SECTION")) {
                    ForEach(availableToAdd, id: \.code) { item in
                        Button {
                            withAnimation {
                                languages.append(item.code)
                                persistChanges()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.displayName)
                                        .foregroundStyle(.primary)
                                    Text(item.code)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    withAnimation {
                        store.resetToDefault()
                        languages = store.priorityOrder
                    }
                } label: {
                    Text(ForkL10n.string("METADATA_PRIORITY_RESET_BUTTON"))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .disabled(languages == TitleLanguagePriorityStore.defaultOrder)
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(ForkL10n.string("METADATA_TITLE_LANGUAGE_PRIORITY"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func persistChanges() {
        store.priorityOrder = languages
        languages = store.priorityOrder
    }
}
