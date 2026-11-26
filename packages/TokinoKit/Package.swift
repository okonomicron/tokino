// swift-tools-version: 6.2
import PackageDescription

// TokinoKit is deliberately platform-agnostic: it imports only Foundation, so it
// compiles and tests on Linux in CI (free) as well as on iOS. Anything that needs
// PhotoKit, SwiftUI or UIKit belongs in the `ios/` app target, not here.
// See docs/ARCHITECTURE.md ("The cloud-first lever").
let package = Package(
    name: "TokinoKit",
    platforms: [.iOS(.v26), .macOS(.v14)],
    products: [
        .library(name: "TokinoKit", targets: ["TokinoKit"])
    ],
    targets: [
        .target(
            name: "TokinoKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TokinoKitTests",
            dependencies: ["TokinoKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
