// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxHarnessMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "cmux-harness-mac", targets: ["CmuxHarnessMac"])
    ],
    targets: [
        .executableTarget(
            name: "CmuxHarnessMac"
        )
    ]
)
