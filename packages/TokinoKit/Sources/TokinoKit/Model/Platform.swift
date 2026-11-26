import Foundation

/// A publishing destination. New platforms arrive as cases here plus an adapter,
/// per the brief's requirement (§8, §17.8) that platforms be modular.
public enum Platform: String, Codable, Sendable, CaseIterable, Hashable {
    case instagram
    case xiaohongshu

    public var displayName: String {
        switch self {
        case .instagram: return "Instagram"
        case .xiaohongshu: return "Xiaohongshu"
        }
    }

    /// How content reaches the platform.
    public enum PublishingMode: String, Codable, Sendable, Hashable {
        /// We call an official API and the post appears without the user acting.
        case officialAPI
        /// We prepare everything, then hand off to the platform's own app for
        /// the user to complete. The only compliant route where no publishing
        /// API exists.
        case assistedHandoff
    }

    /// Verified 2026-11: Xiaohongshu's open platform (open.xiaohongshu.com) is a
    /// merchant/e-commerce platform covering orders, products and inventory. It
    /// exposes no note-publishing API and is closed to open registration, so
    /// automated posting is not available at any access tier. Assisted handoff
    /// is the only compliant option; see docs/DECISIONS.md.
    public var publishingMode: PublishingMode {
        switch self {
        case .instagram: return .officialAPI
        case .xiaohongshu: return .assistedHandoff
        }
    }

    public var constraints: PlatformConstraints {
        switch self {
        case .instagram: return .instagram
        case .xiaohongshu: return .xiaohongshu
        }
    }
}

/// Hard limits a platform imposes on content.
///
/// These are data, not scattered `if` statements, so the content generator can
/// validate a draft before we waste an API call or, worse, get a post rejected
/// after publishing began.
public struct PlatformConstraints: Sendable, Hashable, Codable {
    public let maxCaptionLength: Int
    public let maxHashtags: Int
    public let maxCarouselItems: Int
    public let minVideoDuration: TimeInterval
    public let maxVideoDuration: TimeInterval
    public let maxImageBytes: Int
    public let maxVideoBytes: Int
    /// Image formats the platform will accept for an API upload.
    public let acceptedImageFormats: Set<String>
    /// Whether media must be reachable at a public URL at publish time, rather
    /// than uploaded as bytes.
    public let requiresPubliclyHostedMedia: Bool

    public init(
        maxCaptionLength: Int,
        maxHashtags: Int,
        maxCarouselItems: Int,
        minVideoDuration: TimeInterval,
        maxVideoDuration: TimeInterval,
        maxImageBytes: Int,
        maxVideoBytes: Int,
        acceptedImageFormats: Set<String>,
        requiresPubliclyHostedMedia: Bool
    ) {
        self.maxCaptionLength = maxCaptionLength
        self.maxHashtags = maxHashtags
        self.maxCarouselItems = maxCarouselItems
        self.minVideoDuration = minVideoDuration
        self.maxVideoDuration = maxVideoDuration
        self.maxImageBytes = maxImageBytes
        self.maxVideoBytes = maxVideoBytes
        self.acceptedImageFormats = acceptedImageFormats
        self.requiresPubliclyHostedMedia = requiresPubliclyHostedMedia
    }

    /// Verified 2026-11 against Meta's Instagram Platform content-publishing docs.
    /// JPEG is the only accepted image format; media must be fetchable by Meta
    /// at publish time ("we cURL media used in publishing attempts").
    public static let instagram = PlatformConstraints(
        maxCaptionLength: 2200,
        maxHashtags: 30,
        maxCarouselItems: 20,
        minVideoDuration: 3,
        maxVideoDuration: 15 * 60,
        maxImageBytes: 8 * 1_048_576,
        maxVideoBytes: 300 * 1_048_576,
        acceptedImageFormats: ["jpeg", "jpg"],
        requiresPubliclyHostedMedia: true
    )

    /// Assisted handoff, so these are the app's own composer limits rather than
    /// API limits, and are best-effort. Media is exported to the photo library
    /// locally, never hosted by us — hence no public-hosting requirement.
    /// Marked for confirmation during the M6 handoff work.
    public static let xiaohongshu = PlatformConstraints(
        maxCaptionLength: 1000,
        maxHashtags: 20,
        maxCarouselItems: 18,
        minVideoDuration: 1,
        maxVideoDuration: 15 * 60,
        maxImageBytes: 32 * 1_048_576,
        maxVideoBytes: 1024 * 1_048_576,
        acceptedImageFormats: ["jpeg", "jpg", "png", "heic"],
        requiresPubliclyHostedMedia: false
    )
}
