// swift-tools-version: 6.0

import Foundation
import PackageDescription

let infoPlistPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/Info.plist")
    .path

// Command Line Tools Swift 6.4 omits TestingMacros from the emit-module plugin path on swiftbuild.
let cltTestingPluginPath = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
let testSwiftSettings: [SwiftSetting] = (
    !FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Developer") &&
    FileManager.default.fileExists(atPath: cltTestingPluginPath)
) ? [.unsafeFlags(["-plugin-path", cltTestingPluginPath])] : []

let package = Package(
    name: "daykit",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DaykitCore", targets: ["DaykitCore"]),
        .executable(name: "daykit", targets: ["daykit"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "DaykitCore"
        ),
        .executableTarget(
            name: "daykit",
            dependencies: ["DaykitCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", infoPlistPath
                ])
            ]
        ),
        .testTarget(
            name: "DaykitTests",
            dependencies: ["DaykitCore"],
            swiftSettings: testSwiftSettings
        )
    ]
)
