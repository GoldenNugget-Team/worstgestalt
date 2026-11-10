// swift-tools-version: 6.2

import PackageDescription
let package = Package(
    name: "worsegestalt",
    platforms: [
        // Minimum deployment: iOS 26.0 (the app targets iOS 26.x / 27.x).
        .iOS(.v26),
    ],
    products: [
        // An xtool project must contain exactly one library product for the app.
        .library(
            name: "worsegestalt",
            targets: ["WorseGestalt"]
        ),
    ],
    targets: [
        // The only remaining ObjC target: the worse_query exploit itself
        // (forcequitOS, GPL-3.0). The escape engine lives in Swift in the
        // WorseGestalt target (Sources/WorseGestalt/BQCore.swift).
        .target(
            name: "CQueryBridges"
        ),

        // The app itself.
        .target(
            name: "WorseGestalt",
            dependencies: ["CQueryBridges"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
