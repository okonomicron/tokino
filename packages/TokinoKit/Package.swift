// swift-tools-version: 6.1
import PackageDescription

// TokinoKit is deliberately platform-agnostic: it imports only Foundation, so it
// compiles and tests on Linux in CI (free) as well as on iOS. Anything that needs
// PhotoKit, SwiftUI or UIKit belongs in the `ios/` app target, not here.
// See docs/ARCHITECTURE.md ("The cloud-first lever").
let package = Package(
    name: "TokinoKit",
    // Deliberately NOT the app's iOS 26 floor. TokinoKit imports only
    // Foundation and uses no version-gated API, so tying it to the app's
    // deployment target would force every consumer — and every CI toolchain —
    // to be that new for no benefit. The app target sets its own iOS 26
    // minimum in ios/project.yml.
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "TokinoKit", targets: ["TokinoKit"])
    ],
    targets: [
        .target(
            name: "TokinoKit",
            // Copied rather than processed: these are opaque data files and
            // SwiftPM's resource processing would gain us nothing.
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "TokinoKitTests",
            dependencies: ["TokinoKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
