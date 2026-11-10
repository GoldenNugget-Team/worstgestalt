//
//  GestaltStore.swift
//  worsegestalt
//
//  Owns access to the MobileGestalt cache plist:
//  acquire lease → read → edit CacheExtra in memory → serialize →
//  auto-backup → write in place → verify → release lease.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
@MainActor
final class GestaltStore: ObservableObject {
    enum State: Equatable {
        case idle
        case busy
        case loaded
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var dict: [String: Any] = [:]
    @Published private(set) var cacheExtra: [String: Any] = [:]
    @Published private(set) var targetPath = ""
    @Published private(set) var lastBackend = ""
    @Published private(set) var isDirty = false
    @Published private(set) var backups: [GestaltBackup] = []

    /// Blocking C/file work happens here; the main actor only snapshots
    /// returned values. Ops never hold state across calls: each one
    /// acquires its own lease and releases it when done.
    private let queue = DispatchQueue(label: "cc.worsegestalt.store", qos: .userInitiated)

    private var busy = false

    /// The MobileGestalt system-group caches dir (the escape target). The
    /// KAMUI engine resolves the exact plist path per attempt.
    static let kMGCaches: String = SandboxEscape.gestaltTarget

    // MARK: - Public API

    func load() async {
        guard !busy else { return }
        busy = true
        state = .busy
        defer { busy = false }
        do {
            let out = try await queue.run { try Self.loadOperation() }
            targetPath = out.path
            lastBackend = out.backend
            dict = out.parsed
            cacheExtra = (out.parsed["CacheExtra"] as? [String: Any]) ?? [:]
            rebuildEntryCache()
            isDirty = false
            state = .loaded
            await refreshBackups()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func save() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let payload = dict
            let backupName = try await queue.run {
                try Self.saveOperation(payload: payload)
            }
            isDirty = false
            UILogger.log("[store] saved: \(backupName). Respring to apply.")
            await refreshBackups()
            if state != .loaded { state = .loaded }
        } catch {
            // The write work runs on the background queue; never hijack the
            // whole UI with a busy state here — surface the failure in the log.
            UILogger.log("[store] save failed: \(error.localizedDescription)")
            if state != .loaded { state = .loaded }
        }
    }

    func restore(_ backup: GestaltBackup) async {
        guard !busy else { return }
        busy = true
        state = .busy
        defer { busy = false }
        do {
            let url = backup.url
            try await queue.run {
                try Self.restoreOperation(backupURL: url)
            }
            UILogger.log("[store] restored \(backup.fileName)")
            await load()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func deleteBackup(_ backup: GestaltBackup) async {
        try? FileManager.default.removeItem(at: backup.url)
        await refreshBackups()
    }

    func refreshBackups() async {
        do {
            backups = try GestaltBackup.list()
        } catch {
            backups = []
            UILogger.log("[store] backup list failed: \(error.localizedDescription)")
        }
    }

    // MARK: - In-memory editing

    /// Rows in sorted-key order plus their lowercased search haystacks,
    /// rebuilt only when cacheExtra changes. Per-keystroke rendering then
    /// just filters these instead of mapping ~940 keys on every body pass.
    private var cachedEntries: [GestaltEntry] = []
    private var cachedEntryHaystacks: [String] = []

    private func rebuildEntryCache() {
        var rows: [GestaltEntry] = []
        var haystacks: [String] = []
        rows.reserveCapacity(cacheExtra.count)
        haystacks.reserveCapacity(cacheExtra.count)
        for (key, value) in cacheExtra.sorted(by: { $0.key < $1.key }) {
            let kind = PlistValueKind.kind(of: value)
            let entry = GestaltEntry(
                key: key,
                kind: kind,
                summary: GestaltEntry.summary(of: value, kind: kind)
            )
            rows.append(entry)
            haystacks.append("\(entry.readableName) \(key) \(entry.summary)".lowercased())
        }
        cachedEntries = rows
        cachedEntryHaystacks = haystacks
    }

    func entries(query: String) -> [GestaltEntry] {
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lowered.isEmpty else { return cachedEntries }
        return zip(cachedEntries, cachedEntryHaystacks).compactMap { entry, haystack in
            haystack.contains(lowered) ? entry : nil
        }
    }

    func setEntry(key: String, kind: PlistValueKind, text: String) throws {
        var updated = cacheExtra
        updated[key] = try PlistValueKind.parse(text, as: kind)
        commit(cacheExtra: updated)
    }

    func removeEntry(key: String) {
        var updated = cacheExtra
        updated.removeValue(forKey: key)
        commit(cacheExtra: updated)
    }

    func setValue(_ rawValue: Any, forKey key: String) {
        var updated = cacheExtra
        updated[key] = rawValue
        commit(cacheExtra: updated)
    }

    private func commit(cacheExtra updated: [String: Any]) {
        cacheExtra = updated
        dict["CacheExtra"] = updated
        rebuildEntryCache()
        isDirty = true
    }

    // MARK: - Ops (run on the serial queue; pure + C-bridge only)

    struct LoadOutput {
        let path: String
        let backend: String
        let parsed: [String: Any]
    }

    private static func loadOperation() throws -> LoadOutput {
        let lease = try SandboxEscape.lease()
        defer { lease.release() }
        guard lease.handle >= 0 else {
            throw PlistValueError("no extension handle")
        }
        let path = lease.plistPath
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try RawPlist(data: data).parse()

        // Safety net: keep a pristine copy in the engine's backup slot once,
        // so the restore path always has a valid original on hand.
        let bp = BQ.backupPath()
        if !bp.isEmpty, !FileManager.default.fileExists(atPath: bp) {
            try? data.write(to: URL(fileURLWithPath: bp), options: .atomic)
            UILogger.log("[store] pristine backup written to \(bp)")
        }
        return LoadOutput(path: path, backend: lease.backend.rawValue, parsed: parsed)
    }

    private static func saveOperation(payload: [String: Any]) throws -> String {
        let lease = try SandboxEscape.lease()
        defer { lease.release() }
        guard lease.handle >= 0 else {
            throw PlistValueError("no extension handle")
        }
        let path = lease.plistPath

        // 1. Per-save backup of the raw bytes currently on disk.
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let backup = try GestaltBackup.make()
        try raw.write(to: backup.url, options: .atomic)

        // 2. Serialize the edited tree, preserving the on-disk format.
        var format = PropertyListSerialization.PropertyListFormat.binary
        _ = try? PropertyListSerialization.propertyList(from: raw, format: &format)
        let data = try PropertyListSerialization.data(
            fromPropertyList: payload,
            format: format,
            options: 0
        )

        // 3. In-place write: open/truncate/write/fsync. A rename would
        //    create a new inode and lose our extension-scoped vnode.
        try inPlaceWrite(data: data, to: path)

        // 4. Read back and verify. Binary plist re-serialization is not
        //    bit-stable across passes (key ordering may differ), so compare
        //    structurally instead of comparing serialized bytes.
        let verifyRaw = try Data(contentsOf: URL(fileURLWithPath: path))
        let verify = try RawPlist(data: verifyRaw).parse()
        guard plistEqual(verify, payload) else {
            throw PlistValueError("Post-write verification mismatch. Restore the backup!")
        }
        return backup.fileName
    }

    private static func restoreOperation(backupURL: URL) throws {
        let lease = try SandboxEscape.lease()
        defer { lease.release() }
        guard lease.handle >= 0 else {
            throw PlistValueError("no extension handle")
        }
        let path = lease.plistPath
        // Confirm the cache exists before clobbering anything.
        _ = try Data(contentsOf: URL(fileURLWithPath: path))
        let data = try Data(contentsOf: backupURL)
        try inPlaceWrite(data: data, to: path)
    }

    private static func inPlaceWrite(data: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else {
            throw PlistValueError("open(\(path)) failed: errno=\(errno)")
        }
        defer { close(fd) }
        guard ftruncate(fd, 0) == 0, lseek(fd, 0, SEEK_SET) == 0 else {
            throw PlistValueError("truncate/lseek failed: errno=\(errno)")
        }
        var ok = true
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while ok && offset < data.count {
                let written = write(fd, buffer.baseAddress! + offset, data.count - offset)
                if written <= 0 {
                    ok = false
                } else {
                    offset += written
                }
            }
        }
        guard ok, fsync(fd) == 0 else {
            throw PlistValueError("write/fsync failed: errno=\(errno)")
        }
    }
}

/// Deep structural equality for deserialized property lists. NSNumber bridges
/// both integers and booleans, so numeric comparison accepts 1 == true, which
/// is exactly the same equivalence the binary plist writer applies.
private func plistEqual(_ a: Any, _ b: Any) -> Bool {
    if let an = a as? NSNumber, let bn = b as? NSNumber {
        if an.isEqual(bn) { return true }
        return an.compare(bn) == .orderedSame
    }
    if let as_ = a as? String, let bs = b as? String { return as_ == bs }
    if let ad = a as? Data, let bd = b as? Data { return ad == bd }
    if let aa = a as? [Any], let ba = b as? [Any] {
        guard aa.count == ba.count else { return false }
        return zip(aa, ba).allSatisfy { plistEqual($0, $1) }
    }
    if let ad = a as? [String: Any], let bd = b as? [String: Any] {
        guard ad.count == bd.count else { return false }
        return ad.allSatisfy { key, value in
            bd[key].map { plistEqual($0, value) } ?? false
        }
    }
    if a is NSNull && b is NSNull { return true }
    return false
}

/// Lazily parses a raw plist blob.
struct RawPlist {
    let data: Data

    func parse() throws -> [String: Any] {
        var format = PropertyListSerialization.PropertyListFormat.binary
        let object = try PropertyListSerialization.propertyList(from: data, format: &format)
        guard let dict = object as? [String: Any] else {
            throw PlistValueError("MobileGestalt plist top level is not a dictionary.")
        }
        return dict
    }

    var format: PropertyListSerialization.PropertyListFormat {
        var probe = PropertyListSerialization.PropertyListFormat.binary
        _ = try? PropertyListSerialization.propertyList(from: data, format: &probe)
        return probe
    }
}

private extension DispatchQueue {
    func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            self.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
