//
//  BackupsView.swift
//  worsegestalt
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UniformTypeIdentifiers

struct BackupsView: View {
    @ObservedObject var store: GestaltStore
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Every save makes an automatic backup of the raw plist bytes. Restore rewrites those bytes in place.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    Button {
                        importing = true
                    } label: {
                        Label("Import backup…", systemImage: "square.and.arrow.down")
                    }
                }

                Section("Stored backups") {
                    if store.backups.isEmpty {
                        Text("No backups yet.")
                            .foregroundColor(.secondary)
                    }
                    ForEach(store.backups.reversed()) { backup in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(backup.displayName)
                                    .font(.footnote.monospaced())
                                Spacer()
                                ShareLink(item: backup.url) {
                                    Image(systemName: "square.and.arrow.up")
                                }
                                .buttonStyle(.borderless)
                                Button {
                                    Task { await store.restore(backup) }
                                } label: {
                                    Image(systemName: "arrow.uturn.left.circle")
                                }
                                .buttonStyle(.borderless)
                                .disabled(store.state == .busy)
                                Button(role: .destructive) {
                                    Task { await store.deleteBackup(backup) }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            Text(backup.date, style: .date)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Backups")
            .fileImporter(
                isPresented: $importing,
                allowedContentTypes: [.propertyList, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        importBackup(from: url)
                    }
                case .failure(let error):
                    UILogger.log("[backup] import failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func importBackup(from selected: URL) {
        let accessed = selected.startAccessingSecurityScopedResource()
        defer { if accessed { selected.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: selected)
            _ = try RawPlist(data: data).parse() // sanity-check it's a plist
            let backup = try GestaltBackup.make()
            try data.write(to: backup.url, options: .atomic)
            UILogger.log("[backup] imported as \(backup.fileName)")
            Task { await store.refreshBackups() }
        } catch {
            UILogger.log("[backup] import failed: \(error.localizedDescription)")
        }
    }
}
