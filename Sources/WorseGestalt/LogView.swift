//
//  LogView.swift
//  worsegestalt
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import UIKit

struct LogView: View {
    @ObservedObject private var logger = UILogger.shared
    @ObservedObject private var store = GestaltStoreObserver.proxy
    @State private var class2Fallback = BQ.class2ParentEnabled

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    Text(logger.text.isEmpty ? "No output yet." : logger.text)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                Divider()
                Toggle("Class-2 fallback (experimental)", isOn: $class2Fallback)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .onChange(of: class2Fallback) { _, on in
                        BQ.class2ParentEnabled = on
                        UILogger.log("[engine] class-2 fallback = \(on ? "on" : "off")")
                    }
            }
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy log") { copyLogs() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Engine log") { SandboxEscape.pumpEngineLog() }
                }
                ToolbarItem(placement: .navigation) {
                    Button("Clear") { logger.clear() }
                }
            }
        }
    }

    /// Copies the in-app log plus the engine's own bqtool.log to the pasteboard
    /// so it can be pasted straight into a chat.
    private func copyLogs() {
        var all = "=== worsegestalt app log (\(Date())) ===\n\(logger.text)\n"
        let path = BQ.logPath()
        if !path.isEmpty,
           FileManager.default.fileExists(atPath: path),
           let data = FileManager.default.contents(atPath: path),
           let text = String(data: data, encoding: .utf8) {
            all += "=== engine log \(path) ===\n\(text)"
        } else {
            all += "=== engine log: not found at \(path.isEmpty ? "(nil)" : path) ===\n"
        }
        UIPasteboard.general.string = all
        UILogger.log("[log] copied to clipboard (\(all.count) chars) — paste it wherever you need")
    }
}

/// Log tab shouldn't own a second store; this read-only proxy surfaces
/// connection info without driving it.
@MainActor
enum GestaltStoreObserver {
    static let proxy = ProxyStore()

    @MainActor
    final class ProxyStore: ObservableObject {
        var info: String {
            let os = ProcessInfo.processInfo.operatingSystemVersion
            return "iOS \(os.majorVersion).\(os.minorVersion) (\(os.patchVersion))"
        }
    }
}
