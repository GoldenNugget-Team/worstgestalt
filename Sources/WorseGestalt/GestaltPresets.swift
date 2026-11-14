//
//  GestaltPresets.swift
//  worsegestalt
//
//  Key/value facts sourced from the Nugget preset ecosystem, the Apple Wiki
//  key list and community findings; the implementation here is original.
//  Spoofing hardware keys is high-risk: the app keeps an automatic backup.
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Sendable wrapper over plist-compatible preset values.
enum PresetValue: Sendable {
    case int(Int)
    case string(String)
    case array([Int])

    var raw: Any {
        switch self {
        case .int(let v): v
        case .string(let v): v
        case .array(let v): v
        }
    }
}

struct GestaltPreset: Identifiable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case display = "Display & Appearance"
        case hardware = "Hardware Capabilities"
        case stageManager = "iPad Capabilities"
        case internal_ = "Internal & Research"

        var id: String { rawValue }
    }

    let id: String
    let category: Category
    let title: String
    let detail: String
    let isRisky: Bool
    /// key → value; capability keys are 1/0 ints like most cached booleans.
    let assignments: [String: PresetValue]
    /// Assignments applied when the preset is disabled (nil = same as on).
    let offAssignments: [String: PresetValue]?

    init(
        id: String,
        category: Category,
        title: String,
        detail: String,
        isRisky: Bool = false,
        on: [String: PresetValue],
        off: [String: PresetValue]? = nil
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.isRisky = isRisky
        self.assignments = on
        self.offAssignments = off
    }

    static func flag(_ b: Bool) -> PresetValue { .int(b ? 1 : 0) }

    static let catalog: [GestaltPreset] = [
        GestaltPreset(
            id: "boot-chime",
            category: .hardware,
            title: "Boot & Shutdown Chime",
            detail: "Plays the classic Mac chime at boot/shutdown.",
            on: ["QHxt+hGLaBPbQJbXiUJX3w": .int(1)], // DeviceSupportsBootChime
            off: ["QHxt+hGLaBPbQJbXiUJX3w": .int(0)]
        ),
        GestaltPreset(
            id: "charge-limit",
            category: .hardware,
            title: "80% Charge Limit Menu",
            detail: "Shows the charge limit settings menu; actual capping needs hardware support.",
            on: ["37NVydb//GP/GrhuTN+exg": .int(1)], // DeviceSupports80ChargeLimit
            off: ["37NVydb//GP/GrhuTN+exg": .int(0)]
        ),
        GestaltPreset(
            id: "tap-to-wake",
            category: .hardware,
            title: "Tap to Wake",
            detail: "For devices such as iPhone SE where it is disabled.",
            on: ["yZf3GTRMGTuwSV/lD7Cagw": .int(1)], // DeviceSupportsTapToWake
            off: ["yZf3GTRMGTuwSV/lD7Cagw": .int(0)]
        ),
        GestaltPreset(
            id: "collision-sos",
            category: .hardware,
            title: "Collision SOS",
            detail: "Shows crash detection settings page.",
            on: ["HCzWusHQwZDea6nNhaKndw": .int(1)], // DeviceSupportsCollisionSOS
            off: ["HCzWusHQwZDea6nNhaKndw": .int(0)]
        ),
        GestaltPreset(
            id: "apple-pencil",
            category: .hardware,
            title: "Apple Pencil Settings",
            detail: "Shows the Apple Pencil settings page.",
            on: ["yhHcB0iH0d1XzPO/CFd3ow": .int(1)], // DeviceSupportsApplePencil
            off: ["yhHcB0iH0d1XzPO/CFd3ow": .int(0)]
        ),
        GestaltPreset(
            id: "camera-control",
            category: .hardware,
            title: "Camera Control Settings",
            detail: "Camera Control hardware settings page (iPhone 16-style).",
            on: [
                "CwvKxM2cEogD3p+HYgaW0Q": .int(1),  // CameraButtonCapability
                "oOV1jhJbdV3AddkcCg0AEA": .int(1),  // apple-graphics-performance-tier
            ],
            off: [
                "CwvKxM2cEogD3p+HYgaW0Q": .int(0),
                "oOV1jhJbdV3AddkcCg0AEA": .int(1),
            ]
        ),
        GestaltPreset(
            id: "aod",
            category: .display,
            title: "Always-On Display",
            detail: "May increase burn-in risk and battery drain on unsupported devices.",
            isRisky: true,
            on: [
                "2OOJf1VhaM7NxfRok3HbWQ": .int(1), // DeviceSupportsAlwaysOnDisplay
                "j8/Omm6s1lsmTDFsXjsBfA": .int(1), // DeviceSupportsAlwaysOnTime
            ],
            off: [
                "2OOJf1VhaM7NxfRok3HbWQ": .int(0),
                "j8/Omm6s1lsmTDFsXjsBfA": .int(0),
            ]
        ),
        GestaltPreset(
            id: "aod-vibrancy",
            category: .display,
            title: "AOD Vibrancy",
            detail: "Use if AOD renders incorrectly as a flat image.",
            on: ["ykpu7qyhqFweVMKtxNylWA": .int(1)], // DeviceSupportsAODVibrancy
            off: ["ykpu7qyhqFweVMKtxNylWA": .int(0)]
        ),
        GestaltPreset(
            id: "no-parallax",
            category: .display,
            title: "Disable Wallpaper Parallax",
            detail: "Stops wallpaper motion on device tilt.",
            on: [
                "mmu76v66k1dAtghToInT8g": .int(0),   // UIParallaxCapability (hashed)
                "UIParallaxCapability": .int(0),      // plain-name alias
            ],
            off: [
                "mmu76v66k1dAtghToInT8g": .int(1),
                "UIParallaxCapability": .int(1),
            ]
        ),
        GestaltPreset(
            id: "liquid-glass-lowperf",
            category: .display,
            title: "Liquid Glass Low-Performance Mode",
            detail: "IsSolariumLowPerformanceDevice — trade effects for smoothness.",
            on: ["SAGvsp6O6kAQ4fEfDJpC4Q": .int(1)],
            off: ["SAGvsp6O6kAQ4fEfDJpC4Q": .int(0)]
        ),
        GestaltPreset(
            id: "stage-manager",
            category: .stageManager,
            title: "Stage Manager",
            detail: "Marks the device as Stage Manager capable (DeviceSupportsEnhancedMultitasking).",
            on: ["qeaj75wk3HF4DwQ8qbIi7g": .int(1)],
            off: ["qeaj75wk3HF4DwQ8qbIi7g": .int(0)]
        ),
        GestaltPreset(
            id: "ipad-apps",
            category: .stageManager,
            title: "iPad App Compatibility",
            detail: "Allows iPad-optimized apps on iPhone.",
            on: ["9MZ5AdH43csAUajl/dU+IQ": .array([1, 2])],
            off: ["9MZ5AdH43csAUajl/dU+IQ": .array([1])]
        ),
        GestaltPreset(
            id: "internal-install",
            category: .internal_,
            title: "Apple Internal Install",
            detail: "Enables internal flags (Metal HUD, etc.); some services may misbehave.",
            isRisky: true,
            on: ["EqrsVvjcYDdxHBiQmGhAWw": .int(1)], // apple-internal-install
            off: ["EqrsVvjcYDdxHBiQmGhAWw": .int(0)]
        ),
        GestaltPreset(
            id: "internal-storage",
            category: .internal_,
            title: "Internal Storage View",
            detail: "Shows internal system files in Storage settings.",
            isRisky: true,
            on: ["LBJfwOEzExRxzlAnSuI7eg": .int(1)],
            off: ["LBJfwOEzExRxzlAnSuI7eg": .int(0)]
        ),
        GestaltPreset(
            id: "srd",
            category: .internal_,
            title: "Security Research Device",
            detail: "Reports the device as a Security Research Device (SRD).",
            isRisky: true,
            on: ["XYlJKKkj2hztRP1NWWnhlw": .int(1)],
            off: ["XYlJKKkj2hztRP1NWWnhlw": .int(0)]
        ),
    ]
}

// MARK: - Dynamic Island

enum DynamicIslandOption: String, CaseIterable, Identifiable, Sendable {
    case iphone14Pro
    case iphone14ProMax
    case iphone16Pro
    case iphone16ProMax
    case iphoneAir
    case iphone18Pro
    case iphoneDuo

    var id: String { rawValue }

    /// ArtworkDeviceSubType matches the display height of each device.
    var subtype: Int {
        switch self {
        case .iphone14Pro: 2556    // 1179×2556
        case .iphone14ProMax: 2796 // 1290×2796
        case .iphone16Pro: 2622    // 1206×2622
        case .iphone16ProMax: 2868 // 1320×2868
        case .iphoneAir: 2736      // 1260×2736
        case .iphone18Pro: 2622    // 1206×2622 (same panel as 16/17 Pro)
        case .iphoneDuo: 2670      // inner 1878×2670 (outer 1398×2034)
        }
    }

    var title: String {
        switch self {
        case .iphone14Pro: "iPhone 14 Pro"
        case .iphone14ProMax: "iPhone 14 Pro Max"
        case .iphone16Pro: "iPhone 16 Pro"
        case .iphone16ProMax: "iPhone 16 Pro Max"
        case .iphoneAir: "iPhone Air"
        case .iphone18Pro: "iPhone 18 Pro"
        case .iphoneDuo: "iPhone Duo"
        }
    }
}

// MARK: - Model spoof

/// Device profiles for the full model spoof: ProductType + HWModelStr + CPU-SOC.
/// Identifier/board data follows the iPhone identifier tables (The Apple Wiki, ipsw.info).
enum ModelSpoofOption: String, CaseIterable, Identifiable, Sendable {
    case iphone15Pro
    case iphone15ProMax
    case iphone16
    case iphone16Plus
    case iphone16Pro
    case iphone16ProMax
    case iphone17
    case iphone17Pro
    case iphone17ProMax
    case iphoneAir
    case iphone18Pro
    case iphoneDuo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iphone15Pro: "iPhone 15 Pro"
        case .iphone15ProMax: "iPhone 15 Pro Max"
        case .iphone16: "iPhone 16"
        case .iphone16Plus: "iPhone 16 Plus"
        case .iphone16Pro: "iPhone 16 Pro"
        case .iphone16ProMax: "iPhone 16 Pro Max"
        case .iphone17: "iPhone 17"
        case .iphone17Pro: "iPhone 17 Pro"
        case .iphone17ProMax: "iPhone 17 Pro Max"
        case .iphoneAir: "iPhone Air"
        case .iphone18Pro: "iPhone 18 Pro"
        case .iphoneDuo: "iPhone Duo"
        }
    }

    var productType: String {
        switch self {
        case .iphone15Pro: "iPhone16,1"
        case .iphone15ProMax: "iPhone16,2"
        case .iphone16: "iPhone17,3"
        case .iphone16Plus: "iPhone17,4"
        case .iphone16Pro: "iPhone17,1"
        case .iphone16ProMax: "iPhone17,2"
        case .iphone17: "iPhone18,3"
        case .iphone17Pro: "iPhone18,1"
        case .iphone17ProMax: "iPhone18,2"
        case .iphoneAir: "iPhone18,4"
        case .iphone18Pro: "iPhone19,2"
        case .iphoneDuo: "iPhone19,4"
        }
    }

    /// HWModelStr (board configuration).
    var hardwareModel: String {
        switch self {
        case .iphone15Pro: "D83AP"
        case .iphone15ProMax: "D84AP"
        case .iphone16: "D47AP"
        case .iphone16Plus: "D48AP"
        case .iphone16Pro: "D93AP"
        case .iphone16ProMax: "D94AP"
        case .iphone17: "V57AP"
        case .iphone17Pro: "V53AP"
        case .iphone17ProMax: "V54AP"
        case .iphoneAir: "D23AP"
        case .iphone18Pro: "V63AP"
        case .iphoneDuo: "V68AP"
        }
    }

    /// CPU-SOC name.
    var cpuName: String {
        switch self {
        case .iphone15Pro, .iphone15ProMax: "t8130"                              // A17 Pro
        case .iphone16, .iphone16Plus, .iphone16Pro, .iphone16ProMax: "t8140"    // A18 (Pro)
        case .iphone17, .iphone17Pro, .iphone17ProMax, .iphoneAir: "t8150"       // A19 (Pro)
        case .iphone18Pro, .iphoneDuo: "t8160"                                   // A20 Pro
        }
    }

    /// Assignments for a full model spoof (ProductType + HWModelStr + CPU-SOC).
    /// Face ID may stop working; restore from Backups on instability.
    static func assignments(option: ModelSpoofOption) -> [String: PresetValue] {
        [
            "h9jDsbgj7xIVeIQ8S3/X3Q": .string(option.productType),   // ProductType
            "oYicEKzVTz4/CxxE05pEgQ": .string(option.hardwareModel), // HWModelStr
            "5pYKlGnYYBzGvAlIU8RjEQ": .string(option.cpuName),       // CPU-SOC
        ]
    }
}

// MARK: - Siri AI (US region) spoof

enum AIRegionPreset {
    /// Product type → (marketing name, regulatory model).
    static let profiles: [String: (String, String)] = [
        "iPhone16,1": ("iPhone 15 Pro", "A2848"),
        "iPhone16,2": ("iPhone 15 Pro Max", "A2849"),
        "iPhone17,1": ("iPhone 16 Pro", "A3083"),
        "iPhone17,2": ("iPhone 16 Pro Max", "A3084"),
        "iPhone17,3": ("iPhone 16", "A3081"),
        "iPhone17,4": ("iPhone 16 Plus", "A3082"),
        "iPhone17,5": ("iPhone 16e", "A3212"),
        "iPhone19,2": ("iPhone 18 Pro", "A3714"),
        "iPhone19,4": ("iPhone Duo", "A3447"),
        "iPad16,1": ("iPad mini (A17 Pro)", "A2993"),
        "iPad16,2": ("iPad mini (A17 Pro)", "A2995"),
        "iPad16,3": ("iPad Pro 11-inch (M4)", "A2836"),
        "iPad16,4": ("iPad Pro 11-inch (M4)", "A2837"),
        "iPad16,5": ("iPad Pro 13-inch (M4)", "A2925"),
        "iPad16,6": ("iPad Pro 13-inch (M4)", "A2926"),
        "iPad17,1": ("iPad Pro 11-inch (M5)", "A3357"),
        "iPad17,2": ("iPad Pro 13-inch (M5)", "A3358"),
        "iPad17,3": ("iPad Pro 13-inch (M5)", "A3360"),
        "iPad17,4": ("iPad Pro 13-inch (M5)", "A3361"),
    ]

    static let productTypeKey = "0+nc/Udy4WNG8S+Q7a/s1A"

    /// Detects this device's profile: (marketingName, regulatoryModel, productType).
    /// Runs on MainActor because it reads the store snapshot.
    @MainActor
    static func detect() -> (name: String, model: String, productType: String)? {
        guard let store = StoreProbe.current else { return nil }
        let cacheExtra = store.cacheExtra
        var productType = (cacheExtra[productTypeKey] as? String) ?? machineIdentifier
        if profiles[productType] == nil {
            // Strip board suffixes like the "-A" in some registry entries.
            productType = productType.split(separator: "-").first.flatMap(String.init) ?? productType
        }
        guard let profile = profiles[productType] else { return nil }
        return (profile.0, profile.1, productType)
    }

    private static var machineIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else { return "" }
        return String(cString: value)
    }

    /// Region assignments for a natively supported device.
    static func assignments(profile: AIProfile) -> [String: PresetValue] {
        [
            "h63QSdBCiT/z0WU6rdQv6Q": .string("LL"),    // regionCode
            "yK+xavymRGZ3xWc1tb8XDg": .string("LL/A"),  // regionInfo
            "97JDvERpVwO+GHtthIh7hA": .string(profile.regulatoryModel),
        ]
    }

    /// Full spoof for unsupported devices (product type + hardware + CPU).
    /// Face ID may stop working; restore from Backups on instability.
    static func spoofAssignments(profile: AIProfile) -> [String: PresetValue] {
        var assignments = assignments(profile: profile)
        assignments["h9jDsbgj7xIVeIQ8S3/X3Q"] = .string(profile.productType) // ProductType
        assignments["oYicEKzVTz4/CxxE05pEgQ"] = .string("D83AP")            // HWModelStr (iPhone 15 Pro)
        assignments["5pYKlGnYYBzGvAlIU8RjEQ"] = .string("t8130")            // CPU-SOC name (A17 Pro)
        return assignments
    }
}

struct AIProfile: Sendable {
    let name: String
    let model: String
    let productType: String

    var regulatoryModel: String { model }
}

/// Lets the preset engine read the store's cache snapshot without a cycle.
@MainActor
enum StoreProbe {
    static weak var current: GestaltStore?
}
