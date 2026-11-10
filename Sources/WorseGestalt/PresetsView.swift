//
//  PresetsView.swift
//  worsegestalt
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct PresetsView: View {
    @ObservedObject var store: GestaltStore
    @State private var islandStaged = false
    @State private var islandOption: DynamicIslandOption = .iphone14Pro
    @State private var renameStaged = false
    @State private var deviceName = ""
    @State private var aiStaged = false
    @AppStorage("appliedPresets") private var appliedPresetsRaw = ""

    private let artworkKey = "oPeik/9e8lQWMszEjbPzng" // ArtworkTraits
    private let dynamicIslandKey = "YlEtTtHlNesRBMal1CqRaA" // DeviceSupportsDynamicIsland

    private var appliedPresets: Set<String> {
        Set(appliedPresetsRaw.split(separator: "\0").map(String.init))
    }

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                islandSection
                renameSection
                aiSection
                ForEach(GestaltPreset.Category.allCases) { category in
                    presetSection(category)
                }
            }
            .navigationTitle("Presets")
            .onChange(of: islandStaged) { _, staged in applyIsland(stage: staged) }
            .onChange(of: islandOption) { _, _ in if islandStaged { applyIsland(stage: true) } }
            .onChange(of: renameStaged) { _, staged in applyRename(stage: staged) }
            .onChange(of: aiStaged) { _, staged in applyAI(enable: staged) }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var connectionSection: some View {
        Section {
            switch store.state {
            case .loaded:
                Label("Loaded (\(store.cacheExtra.count) entries)", systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundColor(.red)
                Button("Retry") { Task { await store.load() } }
            case .busy:
                ProgressView()
            case .idle:
                Button("Load MobileGestalt cache first") { Task { await store.load() } }
            }
        }
    }

    private var islandSection: some View {
        Section("Dynamic Island") {
            Toggle("Spoof subtype", isOn: $islandStaged)
                .disabled(store.state != .loaded)
            Picker("Subtype", selection: $islandOption) {
                ForEach(DynamicIslandOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .disabled(!islandStaged)
            Text("Edits ArtworkTraits → ArtworkDeviceSubType and flips DeviceSupportsDynamicIsland. Applies on change.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var renameSection: some View {
        Section("Device name (App Store badge)") {
            Toggle("Spoof product description", isOn: $renameStaged)
                .disabled(store.state != .loaded)
            TextField("e.g. iPhone 17 Pro", text: $deviceName)
                .disabled(!renameStaged)
                .autocorrectionDisabled()
                .onChange(of: renameStaged) { _, staged in
                    if staged && !deviceName.isEmpty { applyRename(stage: true) }
                }
                .onSubmit {
                    if renameStaged { applyRename(stage: true) }
                }
            Text("Edits ArtworkTraits → ArtworkDeviceProductDescription.")
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var aiSection: some View {
        Section {
            Toggle("Enable Siri AI (US / LL)", isOn: $aiStaged)
                .disabled(store.state != .loaded)
            if aiStaged, AIRegionPreset.detect() == nil {
                Text("Device not on the supported list: will also spoof product type, hardware and CPU model. Face ID may break; restore from Backups to undo.")
                    .font(.footnote)
                    .foregroundColor(.orange)
            } else if aiStaged, let profile = AIRegionPreset.detect() {
                Text("Detected: \(profile.name) (\(profile.model)). Only region keys will be written.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }        } header: {
            Text("Generative systems")
        } footer: {
            if aiStaged {
                Text("Disabling does not revert — use the Backups tab to restore the original plist.")
                    .font(.footnote)
            }
        }
    }

    private func presetSection(_ category: GestaltPreset.Category) -> some View {
        Section(category.rawValue) {
            ForEach(GestaltPreset.catalog.filter { $0.category == category }) { preset in
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(preset.title, isOn: Binding(
                        get: { appliedPresets.contains(preset.id) },
                        set: { newValue in
                            applyStaged(preset: preset, enabling: newValue)
                        }
                    ))
                    .disabled(store.state != .loaded)
                    Text(preset.detail)
                        .font(.footnote)
                        .foregroundColor(preset.isRisky ? .orange : .secondary)
                }
            }
        }
    }

    // MARK: - Applying

    private func applyStaged(preset: GestaltPreset, enabling: Bool) {
        let assignments = enabling ? preset.assignments : (preset.offAssignments ?? preset.assignments)
        for (key, presetValue) in assignments {
            store.setValue(presetValue.raw, forKey: key)
        }
        var current = Array(appliedPresetsRaw.split(separator: "\0").map(String.init))
        if enabling {
            if !current.contains(preset.id) { current.append(preset.id) }
        } else {
            current.removeAll { $0 == preset.id }
        }
        appliedPresetsRaw = current.joined(separator: "\0")
        Task { await store.save() }
    }

    private func applyIsland(stage: Bool) {
        guard stage, store.state == .loaded else { return }
        var artwork = (store.cacheExtra[artworkKey] as? [String: Any]) ?? [:]
        artwork["ArtworkDeviceSubType"] = islandOption.subtype
        store.setValue(artwork, forKey: artworkKey)
        store.setValue(1, forKey: dynamicIslandKey)
        Task { await store.save() }
    }

    private func applyRename(stage: Bool) {
        guard stage, store.state == .loaded, !deviceName.isEmpty else { return }
        var artwork = (store.cacheExtra[artworkKey] as? [String: Any]) ?? [:]
        artwork["ArtworkDeviceProductDescription"] = deviceName
        store.setValue(artwork, forKey: artworkKey)
        Task { await store.save() }
    }

    private func applyAI(enable: Bool) {
        guard enable, store.state == .loaded else { return }
        if let detected = AIRegionPreset.detect() {
            let profile = AIProfile(name: detected.name, model: detected.model, productType: detected.productType)
            for (key, presetValue) in AIRegionPreset.assignments(profile: profile) {
                store.setValue(presetValue.raw, forKey: key)
            }
            UILogger.log("[ai] region set for \(profile.name) (\(profile.model))")
        } else {
            let spoofProfile = AIProfile(name: "iPhone 15 Pro", model: "A2848", productType: "iPhone16,1")
            for (key, presetValue) in AIRegionPreset.spoofAssignments(profile: spoofProfile) {
                store.setValue(presetValue.raw, forKey: key)
            }
            UILogger.log("[ai] device not supported — spoofing full iPhone 15 Pro profile")
        }
        Task { await store.save() }
    }
}
