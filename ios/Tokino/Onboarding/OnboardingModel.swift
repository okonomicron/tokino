import Foundation
import SwiftUI
import TokinoKit
import UIKit

/// State for the first-run flow.
///
/// Thin on purpose: it holds the authorization status and nothing else. The
/// scan itself is driven by `ScanEngine` in TokinoKit, which is tested on
/// Linux, so there is no logic here worth duplicating in an iOS-only test.
@MainActor
@Observable
final class OnboardingModel {

    private(set) var access: PhotoLibraryAccess = .notDetermined

    private let authorization: PhotoLibraryAuthorization
    private let openURL: @MainActor (URL) -> Void

    init(
        authorization: PhotoLibraryAuthorization = PhotoLibraryAuthorization(),
        openURL: @escaping @MainActor (URL) -> Void = { url in
            UIApplication.shared.open(url)
        }
    ) {
        self.authorization = authorization
        self.openURL = openURL
    }

    /// Re-reads the status.
    ///
    /// Called on appear because the user may have changed it in Settings while
    /// the app was backgrounded, and showing a stale "access is off" message
    /// after they have just turned it on would look broken.
    func refreshAccess() async {
        access = authorization.currentAccess()
    }

    func requestAccess() async {
        access = await authorization.requestAccess()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }
}
