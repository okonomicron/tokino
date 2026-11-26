import Foundation

public enum ContentFormat: String, Codable, Sendable, CaseIterable, Hashable {
    case singleImage
    case carousel
    case video
}

/// A content opportunity the system has spotted but not yet built.
public struct ContentIdea: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<ContentIdea>
    public let strategyID: Identifier<ContentStrategy>
    public let pillarID: Identifier<ContentPillar>?
    public var headline: String
    public var rationale: String
    /// Experiences this idea would draw on. Grounding ideas in real experiences
    /// is what stops the system inventing things the user never did (§17.11).
    public var experienceIDs: [Identifier<Experience>]
    public var suggestedFormat: ContentFormat
    /// 0...1 estimate of how good this opportunity is, used to rank the queue
    /// and to refuse filling a slot with weak content (§5).
    public var score: Double
    public let createdAt: Date

    public init(
        id: Identifier<ContentIdea> = Identifier(),
        strategyID: Identifier<ContentStrategy>,
        pillarID: Identifier<ContentPillar>? = nil,
        headline: String,
        rationale: String,
        experienceIDs: [Identifier<Experience>] = [],
        suggestedFormat: ContentFormat = .carousel,
        score: Double = 0.5,
        createdAt: Date
    ) {
        self.id = id
        self.strategyID = strategyID
        self.pillarID = pillarID
        self.headline = headline
        self.rationale = rationale
        self.experienceIDs = experienceIDs
        self.suggestedFormat = suggestedFormat
        self.score = score.clamped(to: 0...1)
        self.createdAt = createdAt
    }
}

/// A built post for one platform, ready to review.
///
/// One idea becomes several drafts — one per platform — because the brief is
/// explicit that identical content must not go everywhere (§7).
public struct ContentDraft: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<ContentDraft>
    public let ideaID: Identifier<ContentIdea>
    public let strategyID: Identifier<ContentStrategy>
    public let platform: Platform
    public var format: ContentFormat
    public var caption: String
    public var hashtags: [String]
    /// Ordered media. Order is the carousel order and the first item is the cover.
    public var mediaAssetIDs: [Identifier<MediaAsset>]
    /// Location text to include, only ever derived from a PlaceMatch whose
    /// `mayBeStatedAsFact` is true.
    public var locationText: String?
    public var placeMatchID: Identifier<PlaceMatch>?
    /// Language actually used, as a BCP-47 tag.
    public var language: String
    /// Whether a human edited this. Edits are the strongest preference signal
    /// we get, so they are worth recording explicitly (§6).
    public var wasEditedByUser: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: Identifier<ContentDraft> = Identifier(),
        ideaID: Identifier<ContentIdea>,
        strategyID: Identifier<ContentStrategy>,
        platform: Platform,
        format: ContentFormat,
        caption: String,
        hashtags: [String] = [],
        mediaAssetIDs: [Identifier<MediaAsset>] = [],
        locationText: String? = nil,
        placeMatchID: Identifier<PlaceMatch>? = nil,
        language: String = "en",
        wasEditedByUser: Bool = false,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.ideaID = ideaID
        self.strategyID = strategyID
        self.platform = platform
        self.format = format
        self.caption = caption
        self.hashtags = hashtags
        self.mediaAssetIDs = mediaAssetIDs
        self.locationText = locationText
        self.placeMatchID = placeMatchID
        self.language = language
        self.wasEditedByUser = wasEditedByUser
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A render derived from the user's originals — a cropped JPEG, a rendered video.
///
/// Separate from PhotoAsset because originals are never modified (§17.5) and
/// never uploaded wholesale; a MediaAsset is a purpose-built derivative that
/// exists only for an approved draft.
public struct MediaAsset: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<MediaAsset>
    public let userID: Identifier<User>
    /// The library asset this came from, where there is one. Nil for generated
    /// media such as a title card.
    public let sourceAssetID: Identifier<PhotoAsset>?
    public let kind: MediaKind
    /// Path in object storage. Private; served via time-limited signed URLs.
    public let storagePath: String
    public let mimeType: String
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval?
    public let createdAt: Date

    public init(
        id: Identifier<MediaAsset> = Identifier(),
        userID: Identifier<User>,
        sourceAssetID: Identifier<PhotoAsset>? = nil,
        kind: MediaKind,
        storagePath: String,
        mimeType: String,
        byteCount: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval? = nil,
        createdAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.sourceAssetID = sourceAssetID
        self.kind = kind
        self.storagePath = storagePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.createdAt = createdAt
    }
}

/// A connected publishing destination.
///
/// Note what is absent: no password field, ever (§8). Tokens live in the
/// platform keychain on device or encrypted server-side, never in this struct,
/// which is why only a reference and an expiry appear here.
public struct SocialAccount: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<SocialAccount>
    public let userID: Identifier<User>
    public let platform: Platform
    /// The platform's own account identifier.
    public let remoteAccountID: String
    public let handle: String
    /// Opaque reference to the stored credential, not the credential itself.
    public let credentialReference: String?
    public let tokenExpiresAt: Date?
    public let connectedAt: Date
    public var isActive: Bool

    public init(
        id: Identifier<SocialAccount> = Identifier(),
        userID: Identifier<User>,
        platform: Platform,
        remoteAccountID: String,
        handle: String,
        credentialReference: String? = nil,
        tokenExpiresAt: Date? = nil,
        connectedAt: Date,
        isActive: Bool = true
    ) {
        self.id = id
        self.userID = userID
        self.platform = platform
        self.remoteAccountID = remoteAccountID
        self.handle = handle
        self.credentialReference = credentialReference
        self.tokenExpiresAt = tokenExpiresAt
        self.connectedAt = connectedAt
        self.isActive = isActive
    }

    /// Treats a token expiring within the hour as already expired, so a long
    /// publish does not start with a credential that dies mid-flight.
    public func needsReauthentication(asOf now: Date) -> Bool {
        guard let tokenExpiresAt else { return false }
        return tokenExpiresAt.timeIntervalSince(now) < 3600
    }
}

/// One attempt to put one draft on one platform. This is the row the state
/// machine governs.
public struct Publication: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<Publication>
    public let draftID: Identifier<ContentDraft>
    public let socialAccountID: Identifier<SocialAccount>
    public let platform: Platform
    public var state: PublicationState
    public var scheduledFor: Date?
    /// Sent to the platform so a retry cannot create a second post. Generated
    /// once when publishing first starts and never regenerated for this row.
    public var idempotencyKey: String?
    /// The platform's identifier for the live post, once known.
    public var remoteID: String?
    public var attemptCount: Int
    public var lastFailure: PublishFailure?
    public var publishedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: Identifier<Publication> = Identifier(),
        draftID: Identifier<ContentDraft>,
        socialAccountID: Identifier<SocialAccount>,
        platform: Platform,
        state: PublicationState = .idea,
        scheduledFor: Date? = nil,
        idempotencyKey: String? = nil,
        remoteID: String? = nil,
        attemptCount: Int = 0,
        lastFailure: PublishFailure? = nil,
        publishedAt: Date? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.draftID = draftID
        self.socialAccountID = socialAccountID
        self.platform = platform
        self.state = state
        self.scheduledFor = scheduledFor
        self.idempotencyKey = idempotencyKey
        self.remoteID = remoteID
        self.attemptCount = attemptCount
        self.lastFailure = lastFailure
        self.publishedAt = publishedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
