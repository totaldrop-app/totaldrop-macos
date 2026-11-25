// swift-tools-version: 6.0
// SPDX-FileCopyrightText: 2026 The TotalDrop Contributors
// SPDX-License-Identifier: GPL-3.0-or-later

import PackageDescription

let package = Package(
    name: "TotalDropMac",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .executable(
            name: "TotalDropMac",
            targets: ["TotalDropMac"]
        ),
        .library(
            name: "FinderShareExtension",
            type: .dynamic,
            targets: ["FinderShareExtension"]
        ),
    ],
    targets: [
        .target(
            name: "CTotalDropMacFFI",
            path: "Sources/CTotalDropMacFFI",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "TotalDropMac",
            dependencies: ["CTotalDropMacFFI"],
            path: "Sources/TotalDropMac",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("IOKit"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreImage"),
                .linkedFramework("UniformTypeIdentifiers"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "FinderShareExtension",
            path: "Sources/FinderShareExtension",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "TotalDropMacTests",
            dependencies: ["TotalDropMac", "CTotalDropMacFFI"],
            path: "Tests/TotalDropMacTests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
