//
//  SandboxEscape.swift
//  worsegestalt
//
//  Thin Swift adapter over the escape engine in Sources/WorseGestalt/BQCore.swift
//  (Swift port of the KAMUI engine — MIT). The engine walks a multi-strategy
//  chain (bad_query file form, class-13 traversal, geod class-12 symlink,
//  app-group class-7 symlink, class-2 swap / stage / subpath) and picks the
//  first one that works on the running build — iOS 27.0.1–27.2 is supported.
//  It also discovers the App Group from the running process entitlements
//  (SecTask), so it works inside LiveContainer.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum SandboxBackend: String {
    case kamui = "kamui-chain"
}

/// Owns a consumed sandbox extension handle. Call `release()` when done.
struct SandboxLease {
    let handle: Int64
    let backend: SandboxBackend
    /// The target the escape was requested for.
    let path: String
    /// The path the engine handed back (plist file itself, or a directory).
    let linkPath: String

    func release() {
        guard handle >= 0 else { return }
        BQ.endEscape(handle)
    }

    /// Full path of the MobileGestalt plist.
    var plistPath: String {
        if (linkPath as NSString).lastPathComponent == "com.apple.MobileGestalt.plist" {
            return linkPath
        }
        return (linkPath as NSString).appendingPathComponent("com.apple.MobileGestalt.plist")
    }
}

enum SandboxEscapeError: LocalizedError {
    case engineError(Int64, String)

    var errorDescription: String? {
        switch self {
        case .engineError(let code, let text):
            return "escape failed (\(code)): \(text)"
        }
    }
}

enum SandboxEscape {
    /// The MobileGestalt system-group caches directory — the escape target.
    static let gestaltTarget = "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"

    /// Initialises the engine once and runs the strategy chain. Safe to call repeatedly.
    static func lease() throws -> SandboxLease {
        if !BQ.coreInit() {
            UILogger.log("[kamui] core init failed (MCM symbols unresolved)")
            throw SandboxEscapeError.engineError(-1, "engine init failed")
        }
        let (handle, link) = BQ.escape(gestaltTarget)
        let resolved = link ?? gestaltTarget
        if handle < 0 {
            let text = BQ.escapeError(handle) ?? "unknown"
            UILogger.log("[kamui] escape failed: \(handle) — \(text)")
            throw SandboxEscapeError.engineError(handle, text)
        }
        UILogger.log("[kamui] escape ok (handle \(handle)) link=\(resolved)")
        return SandboxLease(handle: handle, backend: .kamui, path: gestaltTarget, linkPath: resolved)
    }

    /// Dumps the engine log (Documents/bqtool.log) into the in-app log.
    static func pumpEngineLog() {
        let path = BQ.logPath()
        guard !path.isEmpty,
              FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").suffix(40)
        for line in lines {
            UILogger.log("[kamui-log] \(line)")
        }
    }
}
