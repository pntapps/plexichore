// swift-tools-version:5.9
// PlexiChore for Mac — host companion app.
// Build:   swift build -c release      (or open this file in Xcode)
// Bundle:  ./scripts/build-app.sh      (produces build/PlexiChore.app with Info.plist + entitlements)

import PackageDescription

let package = Package(
    name: "PlexiChore",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PlexiChore", targets: ["PlexiChore"])
    ],
    targets: [
        // Objective-C shim around the private CoreGraphics CGVirtualDisplay* classes.
        // All classes are looked up at runtime (NSClassFromString) so the binary still
        // launches on a macOS release where Apple removed / renamed them.
        .target(
            name: "CVirtualDisplay",
            path: "Sources/CVirtualDisplay",
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-fobjc-arc"])
            ],
            linkerSettings: [
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation")
            ]
        ),
        .executableTarget(
            name: "PlexiChore",
            dependencies: ["CVirtualDisplay"],
            path: "Sources/PlexiChore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Network"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
