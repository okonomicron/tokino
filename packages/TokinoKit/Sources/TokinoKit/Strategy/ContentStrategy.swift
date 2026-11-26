import Foundation

/// A user's standing instruction, turned into structure.
///
/// The brief's central feature (§5): the user describes a goal in prose and we
/// produce something editable. `originalPrompt` is kept verbatim forever, so the
/// user's own words remain the source of truth and we can re-derive the
/// structure if our interpretation improves.
public struct ContentStrategy: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<ContentStrategy>
    public let userID: Identifier<User>
    public var name: String
    /// The user's original natural-language instruction, never rewritten.
    public let originalPrompt: String
    public var objectives: [String]
    public var targetAudience: String?
    public var pillars: [ContentPillar]
    public var selectionCriteria: PhotoSelectionCriteria
    public var platforms: [Platform]
    public var cadence: PublishingCadence
    public var voiceProfileID: Identifier<VoiceProfile>?
    public var automationLevel: AutomationLevel
    /// Topics or terms the user never wants posted about.
    public var exclusions: [String]
    public var isActive: Bool
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: Identifier<ContentStrategy> = Identifier(),
        userID: Identifier<User>,
        name: String,
        originalPrompt: String,
        objectives: [String] = [],
        targetAudience: String? = nil,
        pillars: [ContentPillar] = [],
        selectionCriteria: PhotoSelectionCriteria = .init(),
        platforms: [Platform] = [],
        cadence: PublishingCadence = .init(postsPerWeek: 3),
        voiceProfileID: Identifier<VoiceProfile>? = nil,
        automationLevel: AutomationLevel = .manual,
        exclusions: [String] = [],
        isActive: Bool = true,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.originalPrompt = originalPrompt
        self.objectives = objectives
        self.targetAudience = targetAudience
        self.pillars = pillars
        self.selectionCriteria = selectionCriteria
        self.platforms = platforms
        self.cadence = cadence
        self.voiceProfileID = voiceProfileID
        self.automationLevel = automationLevel
        self.exclusions = exclusions
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A recurring theme within a strategy, e.g. "Regional seafood specialities".
public struct ContentPillar: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<ContentPillar>
    public var name: String
    public var description: String
    /// Natural-language queries used to find matching photos via the semantic
    /// index. These are what make a pillar actionable rather than decorative.
    public var searchQueries: [String]
    /// Rough share of output this pillar should take, 0...1. Normalised across
    /// a strategy's pillars when planning the calendar.
    public var weight: Double

    public init(
        id: Identifier<ContentPillar> = Identifier(),
        name: String,
        description: String,
        searchQueries: [String] = [],
        weight: Double = 1.0
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.searchQueries = searchQueries
        self.weight = max(0, weight)
    }
}

/// Which photos a strategy may draw on.
public struct PhotoSelectionCriteria: Sendable, Hashable, Codable {
    public var naturalLanguageQuery: String?
    public var earliestDate: Date?
    public var latestDate: Date?
    /// Restrict to assets within this radius of a point, in metres.
    public var nearCoordinate: Coordinate?
    public var radiusMetres: Double?
    public var requiredAlbumNames: [String]
    public var excludedAlbumNames: [String]
    public var mediaKinds: Set<MediaKind>
    /// Minimum quality score, 0...1, from on-device assessment.
    public var minimumQuality: Double

    public init(
        naturalLanguageQuery: String? = nil,
        earliestDate: Date? = nil,
        latestDate: Date? = nil,
        nearCoordinate: Coordinate? = nil,
        radiusMetres: Double? = nil,
        requiredAlbumNames: [String] = [],
        excludedAlbumNames: [String] = [],
        mediaKinds: Set<MediaKind> = [.image, .video],
        minimumQuality: Double = 0.3
    ) {
        self.naturalLanguageQuery = naturalLanguageQuery
        self.earliestDate = earliestDate
        self.latestDate = latestDate
        self.nearCoordinate = nearCoordinate
        self.radiusMetres = radiusMetres
        self.requiredAlbumNames = requiredAlbumNames
        self.excludedAlbumNames = excludedAlbumNames
        self.mediaKinds = mediaKinds
        self.minimumQuality = minimumQuality.clamped(to: 0...1)
    }
}

/// How often and when to publish.
public struct PublishingCadence: Sendable, Hashable, Codable {
    public var postsPerWeek: Int
    /// Preferred local times of day, as minutes from midnight.
    public var preferredTimesOfDay: [Int]
    /// IANA identifier, e.g. "Asia/Tokyo". Time-zone awareness is required (§9).
    public var timeZoneIdentifier: String
    /// Minimum gap between posts, to stop a burst when a backlog clears.
    public var minimumHoursBetweenPosts: Int

    public init(
        postsPerWeek: Int,
        preferredTimesOfDay: [Int] = [12 * 60],
        timeZoneIdentifier: String = "UTC",
        minimumHoursBetweenPosts: Int = 12
    ) {
        self.postsPerWeek = max(0, postsPerWeek)
        self.preferredTimesOfDay = preferredTimesOfDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.minimumHoursBetweenPosts = max(0, minimumHoursBetweenPosts)
    }
}

/// How much the user lets the system act alone (§9).
///
/// Defaults to `.manual` everywhere it is constructed, per the brief's
/// requirement to default to approval-required.
public enum AutomationLevel: String, Codable, Sendable, CaseIterable, Hashable {
    /// Generate suggestions only; the user approves and schedules.
    case manual
    /// Generate and schedule drafts; the user approves before publishing.
    case semiAutomatic
    /// Generate, schedule and publish with no per-post approval.
    case fullyAutomatic

    public var requiresPerPostApproval: Bool {
        switch self {
        case .manual, .semiAutomatic: return true
        case .fullyAutomatic: return false
        }
    }

    /// Fully automatic publishing is only permissible where the platform
    /// officially supports API publishing — an assisted-handoff platform needs
    /// the user to act, so claiming automation there would be a lie (§9).
    public func isPermitted(on platform: Platform) -> Bool {
        switch self {
        case .manual, .semiAutomatic:
            return true
        case .fullyAutomatic:
            return platform.publishingMode == .officialAPI
        }
    }
}
