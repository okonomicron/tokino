import Foundation

/// Identifies a provider implementation and, critically, whether it is a mock.
///
/// The brief (§15) permits mocks during development but requires they be
/// clearly identified and never silently substituted for a real integration.
/// Making `isMock` part of the type's identity — rather than a comment or a
/// build flag — is what lets `ProviderSelector` enforce that mechanically.
public struct ProviderIdentity: Sendable, Hashable, Codable {
    public let name: String
    public let capability: ProviderCapability
    public let isMock: Bool

    public init(name: String, capability: ProviderCapability, isMock: Bool) {
        self.name = name
        self.capability = capability
        self.isMock = isMock
    }

    /// Shown in logs and in the UI wherever mock output could be mistaken for
    /// real output. Deliberately shouty.
    public var displayLabel: String {
        isMock ? "MOCK · \(name) · not a real integration" : name
    }
}

public enum ProviderCapability: String, Sendable, Hashable, Codable, CaseIterable {
    /// Interprets strategy prompts and writes captions.
    case languageModel
    /// Matches coordinates to real-world places.
    case places
    /// Publishes to a social platform.
    case publishing
}

/// Chooses which provider serves a capability.
///
/// The one rule that matters: if a real credential is configured, a mock must
/// not be selected. Without this, a misconfigured environment would quietly
/// produce fake captions that look plausible — exactly the silent substitution
/// the brief forbids.
public enum ProviderSelector {

    public enum SelectionError: Error, Sendable, Hashable, CustomStringConvertible {
        /// A credential exists but only mocks were registered. Failing loudly
        /// beats serving fabricated content to someone expecting the real thing.
        case mockRefusedWhileCredentialPresent(capability: ProviderCapability, mockName: String)
        case noProviderRegistered(capability: ProviderCapability)

        public var description: String {
            switch self {
            case .mockRefusedWhileCredentialPresent(let capability, let mockName):
                return """
                Refusing to use mock provider '\(mockName)' for \(capability.rawValue): \
                a real credential is configured, so mock output would be mistaken for real output. \
                Register a live provider or remove the credential.
                """
            case .noProviderRegistered(let capability):
                return "No provider registered for \(capability.rawValue)."
            }
        }
    }

    /// Resolve a capability to exactly one provider.
    ///
    /// - Parameters:
    ///   - capability: what is needed.
    ///   - candidates: every registered provider for it.
    ///   - hasCredential: whether a real credential for this capability is configured.
    public static func resolve(
        capability: ProviderCapability,
        candidates: [ProviderIdentity],
        hasCredential: Bool
    ) -> Result<ProviderIdentity, SelectionError> {
        let relevant = candidates.filter { $0.capability == capability }
        guard !relevant.isEmpty else {
            return .failure(.noProviderRegistered(capability: capability))
        }

        // Prefer a live provider whenever one is registered, regardless of
        // credential state — a live provider that lacks a credential will fail
        // with a clear auth error, which is more honest than fake output.
        if let live = relevant.first(where: { !$0.isMock }) {
            return .success(live)
        }

        // Only mocks remain. Permissible only when no credential is configured,
        // which is the genuine "developing without keys" case.
        let mock = relevant[0]
        if hasCredential {
            return .failure(
                .mockRefusedWhileCredentialPresent(capability: capability, mockName: mock.name)
            )
        }
        return .success(mock)
    }
}

// MARK: - Capability protocols

/// Interprets a prompt into a strategy, and writes captions.
///
/// Async and throwing because every real implementation is a network call. Kept
/// as a protocol so M4 can add a live provider without touching callers.
public protocol LanguageModelProvider: Sendable {
    static var identity: ProviderIdentity { get }

    /// Turn a user's natural-language instruction into strategy structure.
    func interpretStrategy(
        prompt: String,
        librarySummary: LibrarySummary
    ) async throws -> StrategyInterpretation

    /// Write a caption for one draft on one platform.
    func writeCaption(request: CaptionRequest) async throws -> CaptionResult
}

/// Matches a coordinate to candidate real-world places.
public protocol PlaceProvider: Sendable {
    static var identity: ProviderIdentity { get }

    func findPlaces(
        near coordinate: Coordinate,
        radiusMetres: Double,
        capturedAt: Date?
    ) async throws -> [PlaceCandidate]
}

/// Publishes a draft to one platform.
public protocol PublishingAdapter: Sendable {
    static var identity: ProviderIdentity { get }
    var platform: Platform { get }

    /// Publish, using `idempotencyKey` so a retry cannot create a second post.
    func publish(
        draft: ContentDraft,
        media: [MediaAsset],
        idempotencyKey: String
    ) async throws -> PublishOutcome

    /// Ask the platform whether a post for this idempotency key already exists.
    /// This is what resolves `awaitingReconciliation` without double-posting.
    func reconcile(idempotencyKey: String) async throws -> ReconciliationResult
}

// MARK: - Provider payloads

/// A privacy-preserving digest of the library, for prompting a language model.
///
/// Carries counts, date ranges and place names — never images and never
/// per-photo detail — so interpreting a strategy does not require uploading
/// anything sensitive.
public struct LibrarySummary: Sendable, Hashable, Codable {
    public let totalAssets: Int
    public let earliestCapture: Date?
    public let latestCapture: Date?
    /// Frequent place or region names, most common first.
    public let commonPlaceNames: [String]
    /// Recurring visual themes from the semantic index, most common first.
    public let recurringThemes: [String]

    public init(
        totalAssets: Int,
        earliestCapture: Date? = nil,
        latestCapture: Date? = nil,
        commonPlaceNames: [String] = [],
        recurringThemes: [String] = []
    ) {
        self.totalAssets = totalAssets
        self.earliestCapture = earliestCapture
        self.latestCapture = latestCapture
        self.commonPlaceNames = commonPlaceNames
        self.recurringThemes = recurringThemes
    }
}

/// What a language model proposes for a strategy. The user edits this before it
/// becomes a `ContentStrategy`, per §5.
public struct StrategyInterpretation: Sendable, Hashable, Codable {
    public let suggestedName: String
    public let objectives: [String]
    public let targetAudience: String?
    public let pillars: [ContentPillar]
    public let suggestedPlatforms: [Platform]
    public let suggestedCadence: PublishingCadence
    public let suggestedVoiceInstruction: String
    public let selectionCriteria: PhotoSelectionCriteria

    public init(
        suggestedName: String,
        objectives: [String],
        targetAudience: String?,
        pillars: [ContentPillar],
        suggestedPlatforms: [Platform],
        suggestedCadence: PublishingCadence,
        suggestedVoiceInstruction: String,
        selectionCriteria: PhotoSelectionCriteria
    ) {
        self.suggestedName = suggestedName
        self.objectives = objectives
        self.targetAudience = targetAudience
        self.pillars = pillars
        self.suggestedPlatforms = suggestedPlatforms
        self.suggestedCadence = suggestedCadence
        self.suggestedVoiceInstruction = suggestedVoiceInstruction
        self.selectionCriteria = selectionCriteria
    }
}

public struct CaptionRequest: Sendable, Hashable, Codable {
    public let platform: Platform
    public let language: String
    public let voice: VoiceProfile
    public let pillarName: String?
    /// Grounding facts. Only things we actually know: dates, confirmed venues,
    /// recognised content. The generator must not invent beyond these (§17.11).
    public let groundingFacts: [String]
    public let format: ContentFormat
    public let imageCount: Int

    public init(
        platform: Platform,
        language: String,
        voice: VoiceProfile,
        pillarName: String? = nil,
        groundingFacts: [String] = [],
        format: ContentFormat,
        imageCount: Int
    ) {
        self.platform = platform
        self.language = language
        self.voice = voice
        self.pillarName = pillarName
        self.groundingFacts = groundingFacts
        self.format = format
        self.imageCount = imageCount
    }
}

public struct CaptionResult: Sendable, Hashable, Codable {
    public let caption: String
    public let hashtags: [String]
    /// Which provider produced it, so mock output is traceable after the fact.
    public let producedBy: ProviderIdentity

    public init(caption: String, hashtags: [String], producedBy: ProviderIdentity) {
        self.caption = caption
        self.hashtags = hashtags
        self.producedBy = producedBy
    }
}

public struct PlaceCandidate: Sendable, Hashable, Codable {
    public let providerPlaceID: String
    public let name: String
    public let address: String?
    public let categories: [String]
    public let distanceMetres: Double
    public let coordinate: Coordinate

    public init(
        providerPlaceID: String,
        name: String,
        address: String? = nil,
        categories: [String] = [],
        distanceMetres: Double,
        coordinate: Coordinate
    ) {
        self.providerPlaceID = providerPlaceID
        self.name = name
        self.address = address
        self.categories = categories
        self.distanceMetres = distanceMetres
        self.coordinate = coordinate
    }
}

public enum PublishOutcome: Sendable, Hashable {
    case published(remoteID: String)
    case failed(PublishFailure)
    /// We could not determine the result. The caller must move the row to
    /// `awaitingReconciliation` rather than retrying.
    case outcomeUnknown(reason: String)
}

public enum ReconciliationResult: Sendable, Hashable {
    case foundPublished(remoteID: String)
    case confirmedAbsent
    /// The platform cannot tell us. Stays in reconciliation for a later attempt
    /// rather than guessing.
    case stillUnknown
}
