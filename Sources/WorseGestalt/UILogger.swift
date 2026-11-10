//
//  UILogger.swift
//  worsegestalt
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

@MainActor
final class UILogger: ObservableObject {
    static let shared = UILogger()
    private static let bufferLimit = 200_000

    @Published private(set) var text = ""

    /// Thread-safe entry point: hop to main before touching @Published state.
    nonisolated static func log(_ message: String) {
        let stamp = Self.timestamp()
        Task { @MainActor in
            UILogger.shared.storeLine("\(stamp) \(message)")
        }
    }

    func clear() {
        text = ""
    }

    private func storeLine(_ line: String) {
        if text.count > Self.bufferLimit {
            text = String(text.suffix(Self.bufferLimit / 2))
        }
        text += line + "\n"
    }

    nonisolated private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
