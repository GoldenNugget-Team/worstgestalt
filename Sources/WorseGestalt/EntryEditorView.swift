//
//  EntryEditorView.swift
//  worsegestalt
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

/// Edits a single CacheExtra key.
struct EntryEditorView: View {
    @ObservedObject var store: GestaltStore
    let key: String

    @Environment(\.dismiss) private var dismiss
    @State private var kind: PlistValueKind = .string
    @State private var text = ""
    @State private var synced = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Key") {
                    LabeledContent("Raw key", value: key)
                        .textSelection(.enabled)
                    if let name = GestaltKeyMap.names[key] {
                        LabeledContent("Known as", value: name)
                            .font(.footnote)
                    }
                    if let description = GestaltKeyMap.descriptions[key] {
                        Text(description)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Value") {
                    Picker("Type", selection: $kind) {
                        ForEach(PlistValueKind.allCases) { k in
                            Text(k.label).tag(k)
                        }
                    }

                    if kind == .boolean {
                        Picker("Value", selection: Binding(
                            get: { text.trimmingCharacters(in: .whitespaces).lowercased() == "true" },
                            set: { text = $0 ? "true" : "false" }
                        )) {
                            Text("true").tag(true)
                            Text("false").tag(false)
                        }
                    } else {
                        TextField("Value", text: $text, axis: .vertical)
                            .font(.system(.footnote, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .lineLimit(3...12)
                    }
                    if kind == .data {
                        Text("Base64-encoded raw bytes.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                Section {
                    Button("Write value") {
                        let finalKind = kind
                        let finalText = text
                        do {
                            try store.setEntry(key: key, kind: finalKind, text: finalText)
                            Task {
                                await store.save()
                                dismiss()
                            }
                        } catch {
                            AlertCenter.show(error.localizedDescription)
                        }
                    }
                    .disabled(store.state != .loaded)
                    .disabled(text.isEmpty && kind != .string)

                    Button("Remove key…", role: .destructive) {
                        store.removeEntry(key: key)
                        Task {
                            await store.save()
                            dismiss()
                        }
                    }
                    .disabled(store.state != .loaded)
                } footer: {
                    Text("Every write auto-backs up the plist into Backups first.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Edit entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear {
            if !synced {
                synced = true
                let current = store.cacheExtra[key]
                kind = PlistValueKind.kind(of: current)
                text = PlistValueKind.encode(current, as: kind)
            }
        }
    }
}

/// Sheet for creating a brand-new key.
struct AddEntryView: View {
    @ObservedObject var store: GestaltStore
    @Environment(\.dismiss) private var dismiss

    @State private var key = ""
    @State private var kind: PlistValueKind = .integer
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("New key") {
                    TextField("Key (e.g. QHxt+hGLaBPbQJbXiUJX3w)", text: $key)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Picker("Type", selection: $kind) {
                        ForEach(PlistValueKind.allCases) { k in
                            Text(k.label).tag(k)
                        }
                    }
                    TextField("Value", text: $text, axis: .vertical)
                        .font(.system(.footnote, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .lineLimit(2...10)
                }

                Section("Hint") {
                    Text(GestaltKeyMap.descriptions[key] ?? "Unknown key — double-check before writing.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Add entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add & write") {
                        let finalKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalKind = kind
                        let finalText = text
                        guard !finalKey.isEmpty else { return }
                        do {
                            try store.setEntry(key: finalKey, kind: finalKind, text: finalText)
                            Task {
                                await store.save()
                                dismiss()
                            }
                        } catch {
                            AlertCenter.show(error.localizedDescription)
                        }
                    }
                    .disabled(key.isEmpty || (text.isEmpty && kind != .string))
                    .disabled(store.state != .loaded)
                }
            }
        }
    }
}
