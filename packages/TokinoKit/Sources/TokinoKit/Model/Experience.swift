import Foundation

/// A real-world episode reconstructed from several photos — the brief's major
/// differentiator (§4). One restaurant visit might comprise the food, the
/// exterior, the menu and a receipt; all of it is one Experience.
public struct Experience: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<Experience>
    public let userID: Identifier<User>
    /// Assets in capture order.
    public let assetIDs: [Identifier<PhotoAsset>]
    public let startedAt: Date
    public let endedAt: Date
    /// Centroid of the member assets that carry coordinates.
    public let centroid: Coordinate?
    /// Best place match, once confirmed or inferred.
    public let placeMatchID: Identifier<PlaceMatch>?
    /// A short AI-generated label, e.g. "Lunch near Tsukiji". Editable.
    public let title: String?
    /// Which signals produced this grouping, so the UI can explain itself and
    /// a user correction can teach us which signal misfired.
    public let groupingSignals: Set<GroupingSignal>

    public enum GroupingSignal: String, Codable, Sendable, Hashable, CaseIterable {
        case gpsProximity
        case timeProximity
        case visualSimilarity
        case captureSequence
        case sharedAlbum
        case recognisedSign
        case userConfirmed
    }

    public init(
        id: Identifier<Experience> = Identifier(),
        userID: Identifier<User>,
        assetIDs: [Identifier<PhotoAsset>],
        startedAt: Date,
        endedAt: Date,
        centroid: Coordinate? = nil,
        placeMatchID: Identifier<PlaceMatch>? = nil,
        title: String? = nil,
        groupingSignals: Set<GroupingSignal> = []
    ) {
        self.id = id
        self.userID = userID
        self.assetIDs = assetIDs
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.centroid = centroid
        self.placeMatchID = placeMatchID
        self.title = title
        self.groupingSignals = groupingSignals
    }

    public var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

/// A candidate link between an Experience and a real-world place.
///
/// Deliberately not a fact. The brief is emphatic (§4): never assume the nearest
/// restaurant is the right one, current listings may not reflect a business that
/// existed years ago, and verified facts must be distinguishable from inferences.
/// So confidence and provenance are part of the type, and captions may only
/// assert a place when `isUserConfirmed` or confidence is high.
public struct PlaceMatch: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<PlaceMatch>
    public let experienceID: Identifier<Experience>
    /// Google's place identifier. Per Google Maps Platform terms this may be
    /// cached indefinitely, unlike display fields — see docs/DECISIONS.md.
    public let providerPlaceID: String
    /// Cached for display. Google's terms grant no indefinite caching exception
    /// for display fields, so these are refreshed rather than trusted forever.
    public let cachedName: String
    public let cachedAddress: String?
    /// When the display fields were fetched, so staleness is visible.
    public let cachedAt: Date
    /// Distance from the experience centroid to the place, in metres.
    public let distanceMetres: Double?
    /// 0...1. Derived from distance, corroborating signals and OCR evidence.
    public let confidence: Double
    /// Which signals supported this match, for an explainable UI.
    public let evidence: Set<Evidence>
    /// True once the user has explicitly confirmed. Only then may content state
    /// the venue as fact.
    public let isUserConfirmed: Bool
    /// True when the user rejected this candidate, so we never re-offer it.
    public let isUserRejected: Bool

    public enum Evidence: String, Codable, Sendable, Hashable, CaseIterable {
        case gpsProximity
        case nameFoundInImageText
        case categoryMatchesImageContent
        case openAtCaptureTime
        case userConfirmed
    }

    public init(
        id: Identifier<PlaceMatch> = Identifier(),
        experienceID: Identifier<Experience>,
        providerPlaceID: String,
        cachedName: String,
        cachedAddress: String? = nil,
        cachedAt: Date,
        distanceMetres: Double? = nil,
        confidence: Double,
        evidence: Set<Evidence> = [],
        isUserConfirmed: Bool = false,
        isUserRejected: Bool = false
    ) {
        self.id = id
        self.experienceID = experienceID
        self.providerPlaceID = providerPlaceID
        self.cachedName = cachedName
        self.cachedAddress = cachedAddress
        self.cachedAt = cachedAt
        self.distanceMetres = distanceMetres
        self.confidence = confidence.clamped(to: 0...1)
        self.evidence = evidence
        self.isUserConfirmed = isUserConfirmed
        self.isUserRejected = isUserRejected
    }

    /// Google Maps Platform permits caching place IDs indefinitely but not
    /// display fields. 30 days is the documented ceiling for cached coordinates,
    /// so we use it as the refresh interval for display data too.
    public static let displayCacheLifetime: TimeInterval = 30 * 24 * 3600

    public func needsRefresh(asOf now: Date) -> Bool {
        now.timeIntervalSince(cachedAt) > Self.displayCacheLifetime
    }

    /// Whether content may state this venue as fact.
    ///
    /// The bar is deliberately high: either the user confirmed it, or we have
    /// strong confidence *and* corroboration beyond mere GPS proximity. This is
    /// what stops the app inventing a restaurant name (§17.11).
    public var mayBeStatedAsFact: Bool {
        if isUserRejected { return false }
        if isUserConfirmed { return true }
        let corroborating = evidence.subtracting([.gpsProximity])
        return confidence >= 0.85 && !corroborating.isEmpty
    }
}

extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
