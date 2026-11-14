//
//  ContentView.swift
//  worsegestalt
//
//  Root shell of the app: five tabs (Gestalt / Presets / Backups / Log / About).
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

@MainActor
final class AlertCenter: ObservableObject {
    static let shared = AlertCenter()
    @Published var isPresented = false
    @Published var message = ""

    static func show(_ text: String) {
        shared.message = text
        shared.isPresented = true
    }
}

struct ContentView: View {
    @StateObject private var store = GestaltStore()

    var body: some View {
        TabView {
            GestaltTabView(store: store)
                .tabItem { Label("Gestalt", systemImage: "cpu") }
            PresetsView(store: store)
                .tabItem { Label("Presets", systemImage: "wand.and.stars") }
            BackupsView(store: store)
                .tabItem { Label("Backups", systemImage: "externaldrive") }
            LogView()
                .tabItem { Label("Log", systemImage: "terminal") }
            AboutView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .alert(
            "Worse Gestalt",
            isPresented: Binding(
                get: { AlertCenter.shared.isPresented },
                set: { AlertCenter.shared.isPresented = $0 }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(AlertCenter.shared.message)
        }
        .onAppear {
            StoreProbe.current = store
            RespringAsset.materialize()
            SandboxEscape.pumpEngineLog()
        }
    }
}
