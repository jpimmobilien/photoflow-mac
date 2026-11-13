// swift-tools-version:6.0
//
// PhotoFlow – Intelligent Photo Studio
// Native macOS application (SwiftUI + AppKit). Universal Binary (arm64 + x86_64), macOS 13+.
//
// Open this file in Xcode (File ▸ Open… ▸ Package.swift) to work on the project,
// or run Scripts/build_app.sh to produce PhotoFlow.app and PhotoFlow.dmg.

import PackageDescription

let package = Package(
    name: "PhotoFlow",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PhotoFlow", targets: ["PhotoFlow"])
    ],
    targets: [
        // Apple's Core ML Stable Diffusion pipeline (MIT), vendored with PhotoFlow's inpainting addition.
        .target(
            name: "StableDiffusion",
            path: "Sources/StableDiffusion",
            exclude: ["LICENSE.md", "README.md", "UPSTREAM_REVISION"],
            linkerSettings: [.linkedFramework("CoreML"), .linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "PhotoFlow",
            dependencies: ["StableDiffusion"],
            path: "Sources/PhotoFlow",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreImage"),
                .linkedFramework("Vision"),
                .linkedFramework("Metal"),
                .linkedFramework("QuickLook"),
                .linkedFramework("CoreML")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
