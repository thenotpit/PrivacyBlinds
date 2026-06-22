// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "PrivacyBlinds",
    // iOS 17 is the floor for SwiftUI `layerEffect` + `[[stitchable]]` Metal shaders,
    // which the privacy lens is built on.
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "PrivacyBlinds",
            targets: ["PrivacyBlinds"]
        ),
    ],
    targets: [
        // The `.metal` shader in this target is compiled by SwiftPM into the target's
        // resource bundle (`default.metallib`), reached at runtime via `ShaderLibrary.bundle(.module)`.
        .target(
            name: "PrivacyBlinds"
        ),
        .testTarget(
            name: "PrivacyBlindsTests",
            dependencies: ["PrivacyBlinds"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
