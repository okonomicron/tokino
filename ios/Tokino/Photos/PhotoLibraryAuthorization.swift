import Photos
import TokinoKit

/// What the system will let us see of the photo library.
///
/// Modelled explicitly rather than passing `PHAuthorizationStatus` around,
/// because the three unhappy cases need genuinely different UI. "Limited" in
/// particular is not a failure — the user chose it — and treating it as one is
/// a common and insulting bug.
public enum PhotoLibraryAccess: Equatable, Sendable {
    /// Never asked. The privacy explanation comes before the system prompt.
    case notDetermined
    /// Full library access.
    case full
    /// The user picked specific photos. Everything works, over a smaller set.
    case limited
    /// The user said no. Offer Settings, and do not nag.
    case denied
    /// Blocked by Screen Time or an MDM profile. The user cannot grant it even
    /// if they want to, so offering Settings would be misleading.
    case restricted

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .full
        case .limited: self = .limited
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default:
            // A future case we do not know about is treated as no access, which
            // fails closed rather than assuming permission we may not have.
            self = .denied
        }
    }

    /// Whether any scanning is possible at all.
    public var canReadLibrary: Bool {
        switch self {
        case .full, .limited: return true
        case .notDetermined, .denied, .restricted: return false
        }
    }

    /// Whether sending the user to Settings could actually help.
    public var isResolvableInSettings: Bool {
        switch self {
        case .denied, .limited: return true
        case .notDetermined, .full, .restricted: return false
        }
    }
}

/// Requests and reports photo library access.
public struct PhotoLibraryAuthorization: Sendable {

    public init() {}

    /// The current status, without prompting.
    public func currentAccess() -> PhotoLibraryAccess {
        // .readWrite rather than .addOnly: we need to read the library. We
        // never write to it — the brief requires the original library stay
        // untouched — but PhotoKit offers no read-only level.
        PhotoLibraryAccess(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    /// Prompts if the user has not been asked, and returns the result.
    ///
    /// Call this only *after* showing the privacy explanation. iOS shows the
    /// system prompt once per install; spending it before the user understands
    /// what we do with their photos is a one-shot mistake.
    public func requestAccess() async -> PhotoLibraryAccess {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotoLibraryAccess(status)
    }
}
