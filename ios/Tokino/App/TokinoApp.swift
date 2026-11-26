import SwiftUI

/// Tokino's entry point.
///
/// The app layer stays deliberately thin: domain logic lives in TokinoKit so it
/// can be compiled and tested on Linux for free, rather than consuming macOS CI
/// minutes. See docs/ARCHITECTURE.md.
@main
struct TokinoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
