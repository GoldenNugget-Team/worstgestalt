//
//  Config.swift
//  worsegestalt
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

enum Config {
    /// The App Group identifier used by the worse_query bridge (backend A).
    /// It must match `entitlements.plist` and be registered to the signing identity.
    /// The KAMUI engine reads its own entitlements via SecTask, so this is a
    /// hint for other bridges; it must stay in sync with xtool.yml+entitlements.
    ///
    /// Target id `com.awesomenull.worstgestalt` + group `group.com.awesomenull.worstgestalt`
    /// are blocked by Apple's 10 App-ID-per-7-days free limit (2026-11-09);
    /// swap back once a slot frees and keep engine untouched (SecTask-driven).
    static let appGroup = "group.cc.worsegestalt"
}
