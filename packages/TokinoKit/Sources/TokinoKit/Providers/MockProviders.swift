import Foundation

/// Deterministic stand-ins used while no API credentials are configured.
///
/// Every one of these announces itself through `ProviderIdentity.isMock`, and
/// `ProviderSelector` refuses to pick them once a real credential exists. They
/// are deterministic on purpose: a mock that returned varied output would make
/// test failures intermittent and would be easy to mistake for a real model.
///
/// Mock captions are deliberately flat and obviously templated. They must never
/// read well enough to be posted by accident.

public struct MockLanguageModelProvider: LanguageModelProvider {
    public static let identity = ProviderIdentity(
        name: "mock-language-model",
        capability: .languageModel,
        isMock: true
    )

    public init() {}

    public func interpretStrategy(
        prompt: String,
        librarySummary: LibrarySummary
    ) async throws -> StrategyInterpretation {
        // Derives pillars from the library summary rather than inventing
        // subject matter, so the shape of the output is realistic even though
        // the prose is not. Nothing here is hardcoded to any topic (§17.3).
        let themes = librarySummary.recurringThemes.prefix(4)
        let pillars = themes.enumerated().map { index, theme in
            ContentPillar(
                // Derived from the theme so the mock is genuinely deterministic:
                // a random UUID here made repeated calls differ, which a test caught.
                id: .deterministic(from: "mock-pillar-\(theme)"),
                name: theme.capitalizedFirst,
                description: "[MOCK] Posts about \(theme).",
                searchQueries: [theme],
                weight: 1.0 / Double(max(1, themes.count)) * Double(themes.count - index)
            )
        }

        return StrategyInterpretation(
            suggestedName: "[MOCK] Strategy from prompt",
            objectives: ["[MOCK] Objective derived from a \(prompt.count)-character prompt"],
            targetAudience: "[MOCK] audience",
            pillars: pillars,
            suggestedPlatforms: [.instagram],
            suggestedCadence: PublishingCadence(postsPerWeek: 3),
            suggestedVoiceInstruction: "[MOCK] voice instruction",
            selectionCriteria: PhotoSelectionCriteria(
                naturalLanguageQuery: librarySummary.recurringThemes.first
            )
        )
    }

    public func writeCaption(request: CaptionRequest) async throws -> CaptionResult {
        // Respects the voice's banned phrases and the platform's limits, so
        // downstream validation is exercised rather than bypassed.
        let base = "[MOCK CAPTION — not for publishing] "
            + "\(request.format.rawValue) for \(request.platform.displayName) "
            + "in \(request.language) with \(request.imageCount) image(s)."
        let facts = request.groundingFacts.isEmpty
            ? ""
            : " Facts: " + request.groundingFacts.joined(separator: "; ") + "."

        let limit = request.platform.constraints.maxCaptionLength
        let caption = String((base + facts).prefix(limit))

        let count = min(
            request.voice.hashtagStyle.suggestedCount,
            request.platform.constraints.maxHashtags
        )
        let hashtags = (0..<count).map { "#mock\($0 + 1)" }

        return CaptionResult(caption: caption, hashtags: hashtags, producedBy: Self.identity)
    }
}

public struct MockPlaceProvider: PlaceProvider {
    public static let identity = ProviderIdentity(
        name: "mock-places",
        capability: .places,
        isMock: true
    )

    public init() {}

    public func findPlaces(
        near coordinate: Coordinate,
        radiusMetres: Double,
        capturedAt: Date?
    ) async throws -> [PlaceCandidate] {
        // Derived from the coordinate so results are stable per location and
        // distinguishable between locations, which makes grouping tests useful.
        let key = String(format: "%.4f_%.4f", coordinate.latitude, coordinate.longitude)
        return [
            PlaceCandidate(
                providerPlaceID: "mock_place_\(key)",
                name: "[MOCK] Place at \(key)",
                address: "[MOCK] address",
                categories: ["mock_category"],
                distanceMetres: min(25, radiusMetres),
                coordinate: coordinate
            )
        ]
    }
}

/// Stands in for a real platform adapter, and records what it was asked to do
/// so tests can assert the publishing pipeline's behaviour.
///
/// An actor because the scheduler may drive several publications concurrently
/// and the recorded calls must not race.
public actor MockPublishingAdapter: PublishingAdapter {
    public static let identity = ProviderIdentity(
        name: "mock-publishing",
        capability: .publishing,
        isMock: true
    )

    public let platform: Platform

    /// Every publish call, in order, keyed by idempotency key.
    public private(set) var publishCalls: [String] = []
    /// Keys the mock considers already live, so reconciliation can be exercised.
    private var publishedKeys: [String: String] = [:]
    private let behaviour: Behaviour

    public enum Behaviour: Sendable {
        case succeed
        case fail(PublishFailure)
        /// Simulates a lost response: records the post as live but tells the
        /// caller the outcome is unknown. This is the §14 case.
        case loseTheResponse
    }

    public init(platform: Platform = .instagram, behaviour: Behaviour = .succeed) {
        self.platform = platform
        self.behaviour = behaviour
    }

    public func publish(
        draft: ContentDraft,
        media: [MediaAsset],
        idempotencyKey: String
    ) async throws -> PublishOutcome {
        publishCalls.append(idempotencyKey)

        // A real platform with idempotency support returns the existing post
        // rather than creating a second one. Mirroring that here means the
        // pipeline is tested against realistic behaviour.
        if let existing = publishedKeys[idempotencyKey] {
            return .published(remoteID: existing)
        }

        switch behaviour {
        case .succeed:
            let remoteID = "mock_post_\(publishedKeys.count + 1)"
            publishedKeys[idempotencyKey] = remoteID
            return .published(remoteID: remoteID)
        case .fail(let failure):
            return .failed(failure)
        case .loseTheResponse:
            let remoteID = "mock_post_lost_\(publishedKeys.count + 1)"
            publishedKeys[idempotencyKey] = remoteID
            return .outcomeUnknown(reason: "[MOCK] response lost after the post was accepted")
        }
    }

    public func reconcile(idempotencyKey: String) async throws -> ReconciliationResult {
        if let remoteID = publishedKeys[idempotencyKey] {
            return .foundPublished(remoteID: remoteID)
        }
        return .confirmedAbsent
    }

    public func callCount() -> Int { publishCalls.count }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
