//
//  GestaltTabView.swift
//  worsegestalt
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct GestaltTabView: View {
    @ObservedObject var store: GestaltStore
    @State private var query = ""
    @State private var editingKey: String?
    @State private var addingRecord = false
    @State private var pendingDelete: GestaltEntry?
    @AppStorage("favorites") private var favoriteKeysRaw = ""

    private var favoriteKeys: [String] {
        favoriteKeysRaw.split(separator: "\0").map(String.init)
    }

    var body: some View {
        NavigationStack {
            List {
                statusSection
                if case .loaded = store.state {
                    favoritesSection
                    entriesSection
                    addSection
                }
            }
            .searchable(text: $query, prompt: "Search plaintext name, key or value")
            .navigationTitle("Gestalt")
        }
        .sheet(isPresented: Binding(
            get: { editingKey != nil },
            set: { if !$0 { editingKey = nil } }
        )) {
            if let key = editingKey {
                EntryEditorView(store: store, key: key)
                    .interactiveDismissDisabled(store.isDirty)
            }
        }
        .sheet(isPresented: $addingRecord) {
            AddEntryView(store: store)
        }
        .alert("Delete entry?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { pendingDelete = $0 ? pendingDelete : nil }
        )) {
            Button("Delete", role: .destructive) {
                if let target = pendingDelete {
                    store.removeEntry(key: target.key)
                    Task { await store.save() }
                }
            }
        } message: {
            Text("Removes \(pendingDelete?.key ?? "") from CacheExtra and writes the plist.")
        }
    }

    // MARK: - Sections

    @ViewBuilder private var statusSection: some View {
        Section {
            switch store.state {
            case .idle:
                Text("Not connected.")
                    .foregroundColor(.secondary)
                Button("Load MobileGestalt cache") {
                    Task { await store.load() }
                }
            case .busy:
                HStack {
                    ProgressView()
                    Text("Working…").foregroundColor(.secondary)
                }
            case .loaded:
                VStack(alignment: .leading, spacing: 4) {
                    Label(store.targetPath, systemImage: "checkmark.seal")
                        .font(.caption2)
                        .foregroundStyle(.green)
                        .lineLimit(2)
                    Text("backend: \(store.lastBackend) · \(store.cacheExtra.count) entries")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Button("Reload") { Task { await store.load() } }
                Button("Respring to apply") {
                    if !NeoSpring.trigger() {
                        // No key window — fall back to the engine's own
                        // WebKit respring (file-URL path).
                        RespringAsset.materialize()
                        BQ.respring()
                    }
                }
                    .disabled(store.state != .loaded && !store.isDirty)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundColor(.red)
                Button("Retry") { Task { await store.load() } }
            }
            if store.isDirty && store.state == .loaded {
                Button("Save changes now") { Task { await store.save() } }
            }
        }
    }

    private var favoritesSection: some View {
        Group {
            if !favoriteKeys.isEmpty {
                Section("Favorites") {
                    ForEach(store.entries(query: "").filter { favoriteKeys.contains($0.key) }) { entry in
                        EntryRow(entry: entry)
                            .onTapGesture { editingKey = entry.key }
                    }
                }
            }
        }
    }

    private var entriesSection: some View {
        Section("CacheExtra") {
            ForEach(store.entries(query: query)) { entry in
                EntryRow(entry: entry)
                    .contentShape(Rectangle())
                    .onTapGesture { editingKey = entry.key }
                    .swipeActions(edge: .leading) {
                        Button {
                            toggleFavorite(entry.key)
                        } label: { Image(systemName: favoriteKeys.contains(entry.key) ? "star.fill" : "star") }
                        .tint(.yellow)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = entry } label: {
                            Image(systemName: "trash")
                        }
                    }
            }
        }
    }

    private var addSection: some View {
        Section {
            Button {
                addingRecord = true
            } label: {
                Label("Add entry", systemImage: "plus.circle.fill")
            }
            if store.isDirty {
                Button {
                    Task { await store.save() }
                } label: {
                    Label("Write changes", systemImage: "internaldrive.badge.plus")
                }
            }
        }
    }

    private func toggleFavorite(_ key: String) {
        var current = favoriteKeys
        if let index = current.firstIndex(of: key) {
            current.remove(at: index)
        } else {
            current.append(key)
        }
        favoriteKeysRaw = current.joined(separator: "\0")
    }
}

// MARK: - Row

struct EntryRow: View {
    let entry: GestaltEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(niceName)
                .font(.headline)
            Text(entry.key)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("\(entry.kind.rawValue): \(entry.summary)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 1)
    }

    private var niceName: String {
        GestaltKeyMap.names[entry.key] ?? entry.key
    }
}
