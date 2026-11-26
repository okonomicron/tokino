import Foundation
import Testing
@testable import TokinoKit

/// Every model crosses the wire to Postgres as JSON, so a broken Codable
/// conformance is a data-loss bug. These assert round-trip fidelity, and pin the
/// on-the-wire shape where the database or a hand-edit depends on it.
@Suite("Codable round trips")
struct CodableTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        // Matches what the backend and Postgres use; a mismatch here would show
        // up as drifting timestamps rather than an obvious failure.
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    // MARK: - Identifiers

    @Test("an identifier encodes as a bare UUID string")
    func identifierEncodesAsString() throws {
        let id = Identifier<PhotoAsset>()
        let data = try JSONEncoder().encode(id)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text == "\"\(id.rawValue.uuidString)\"")
        #expect(try JSONDecoder().decode(Identifier<PhotoAsset>.self, from: data) == id)
    }

    @Test("a malformed identifier fails decoding rather than becoming a random UUID")
    func malformedIdentifierThrows() {
        let data = Data("\"not-a-uuid\"".utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(Identifier<PhotoAsset>.self, from: data)
        }
    }

    @Test("deterministic identifiers are stable, well-formed, and seed-sensitive")
    func deterministicIdentifiers() {
        let a = Identifier<ContentPillar>.deterministic(from: "seafood")
        let b = Identifier<ContentPillar>.deterministic(from: "seafood")
        let c = Identifier<ContentPillar>.deterministic(from: "seafood ")

        #expect(a == b, "the same seed must always give the same identifier")
        #expect(a != c, "a different seed must give a different identifier")

        // Must be a valid UUID for Postgres: version 5, RFC 4122 variant.
        let text = a.rawValue.uuidString
        #expect(text.count == 36)
        #expect(text[text.index(text.startIndex, offsetBy: 14)] == "5")
        #expect(UUID(uuidString: text) == a.rawValue)
    }

    // MARK: - Strategy schema

    @Test("a fully populated strategy round-trips")
    func strategyRoundTrips() throws {
        let strategy = ContentStrategy(
            userID: Identifier(),
            name: "Japan Kaisendon",
            originalPrompt: "Find all my photographs of kaisendon taken in Japan over the years.",
            objectives: ["Build an audience around regional seafood"],
            targetAudience: "People who travel in Japan for food",
            pillars: [
                ContentPillar(
                    name: "Restaurant discoveries",
                    description: "Places worth going out of your way for",
                    searchQueries: ["seafood rice bowl", "restaurant exterior"],
                    weight: 0.6
                ),
                ContentPillar(
                    name: "Regional specialities",
                    description: "What each coast is known for",
                    searchQueries: ["uni", "ikura"],
                    weight: 0.4
                )
            ],
            selectionCriteria: PhotoSelectionCriteria(
                naturalLanguageQuery: "kaisendon",
                earliestDate: Self.now.addingTimeInterval(-86400 * 3650),
                nearCoordinate: Coordinate(latitude: 35.6655, longitude: 139.7707),
                radiusMetres: 50_000,
                excludedAlbumNames: ["Screenshots"],
                mediaKinds: [.image],
                minimumQuality: 0.45
            ),
            platforms: [.instagram, .xiaohongshu],
            cadence: PublishingCadence(
                postsPerWeek: 3,
                preferredTimesOfDay: [12 * 60, 19 * 60 + 30],
                timeZoneIdentifier: "Asia/Tokyo",
                minimumHoursBetweenPosts: 24
            ),
            voiceProfileID: Identifier(),
            automationLevel: .semiAutomatic,
            exclusions: ["anything with my family in frame"],
            createdAt: Self.now,
            updatedAt: Self.now
        )

        let decoded = try Self.roundTrip(strategy)
        #expect(decoded == strategy)
        // The user's own words are the source of truth and must survive verbatim.
        #expect(decoded.originalPrompt == strategy.originalPrompt)
        #expect(decoded.pillars.count == 2)
        #expect(decoded.cadence.timeZoneIdentifier == "Asia/Tokyo")
    }

    @Test("a new strategy defaults to requiring approval")
    func strategyDefaultsToManual() {
        let strategy = ContentStrategy(
            userID: Identifier(),
            name: "n",
            originalPrompt: "p",
            createdAt: Self.now,
            updatedAt: Self.now
        )
        // §9: default to approval-required.
        #expect(strategy.automationLevel == .manual)
        #expect(strategy.automationLevel.requiresPerPostApproval)
    }

    // MARK: - Voice profile's custom coding

    /// `[Platform: String]` would otherwise encode as a flat array, which is
    /// unreadable in JSONB and brittle to hand-edit, so it has custom coding.
    @Test("per-platform languages encode as a JSON object")
    func voiceLanguagesEncodeAsObject() throws {
        let voice = VoiceProfile(
            userID: Identifier(),
            name: "Japan traveller",
            instruction: "Knowledgeable, conversational, no influencer language.",
            axes: VoiceAxes(casualness: 0.6, educational: 0.8),
            emojiUsage: .sparing,
            hashtagStyle: .moderate,
            languageByPlatform: [.instagram: "en", .xiaohongshu: "zh-Hans"],
            bannedPhrases: ["hidden gem", "must-try"]
        )

        let data = try JSONEncoder().encode(voice)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let languages = try #require(json["languageByPlatform"] as? [String: String])
        #expect(languages == ["instagram": "en", "xiaohongshu": "zh-Hans"])

        let decoded = try Self.roundTrip(voice)
        #expect(decoded == voice)
        #expect(decoded.language(for: .xiaohongshu) == "zh-Hans")
        #expect(decoded.bannedPhrases == ["hidden gem", "must-try"])
    }

    /// A newer client may write a platform this build does not know. Skipping it
    /// keeps the profile usable instead of failing the whole decode.
    @Test("an unknown platform key is skipped, not fatal")
    func unknownPlatformKeyIsSkipped() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "userID": "\(UUID().uuidString)",
          "name": "v",
          "instruction": "i",
          "languageByPlatform": {"instagram": "en", "threads": "en"}
        }
        """
        let decoded = try JSONDecoder().decode(VoiceProfile.self, from: Data(json.utf8))
        #expect(decoded.languageByPlatform == [.instagram: "en"])
        // Absent fields fall back to documented defaults.
        #expect(decoded.emojiUsage == .sparing)
        #expect(decoded.hashtagStyle == .moderate)
    }

    // MARK: - Other entities

    @Test("a photo asset round-trips, including an absent coordinate")
    func photoAssetRoundTrips() throws {
        let withGPS = PhotoAsset(
            localIdentifier: "ABC-123/L0/001",
            deviceID: Identifier(),
            mediaKind: .image,
            createdAt: Self.now,
            coordinate: Coordinate(latitude: 43.0621, longitude: 141.3544),
            pixelWidth: 4032,
            pixelHeight: 3024,
            albumNames: ["Hokkaido"],
            indexedAt: Self.now
        )
        #expect(try Self.roundTrip(withGPS) == withGPS)

        let withoutGPS = PhotoAsset(
            localIdentifier: "DEF-456",
            deviceID: Identifier(),
            mediaKind: .video,
            pixelWidth: 1920,
            pixelHeight: 1080,
            duration: 12.5
        )
        let decoded = try Self.roundTrip(withoutGPS)
        #expect(decoded == withoutGPS)
        #expect(decoded.coordinate == nil)
        #expect(decoded.createdAt == nil)
    }

    @Test("a publication round-trips with its failure detail intact")
    func publicationRoundTrips() throws {
        let publication = Publication(
            draftID: Identifier(),
            socialAccountID: Identifier(),
            platform: .instagram,
            state: .failed,
            scheduledFor: Self.now.addingTimeInterval(3600),
            idempotencyKey: "tokino-pub-abc123",
            attemptCount: 2,
            lastFailure: PublishFailure(
                kind: .rateLimited,
                message: "quota exhausted",
                retryAfter: Self.now.addingTimeInterval(7200)
            ),
            createdAt: Self.now,
            updatedAt: Self.now
        )
        let decoded = try Self.roundTrip(publication)
        #expect(decoded == publication)
        #expect(decoded.lastFailure?.isRetryable == true)
    }

    @Test("every publication state has a stable raw value")
    func stateRawValuesAreStable() throws {
        // These strings live in Postgres rows; renaming one silently would
        // orphan existing data, so they are pinned here deliberately.
        let expected: [PublicationState: String] = [
            .idea: "idea", .draft: "draft", .review: "review", .approved: "approved",
            .scheduled: "scheduled", .publishing: "publishing", .published: "published",
            .rejected: "rejected", .needsRevision: "needsRevision", .failed: "failed",
            .cancelled: "cancelled", .awaitingReconciliation: "awaitingReconciliation"
        ]
        #expect(Set(expected.keys) == Set(PublicationState.allCases))
        for (state, raw) in expected {
            #expect(state.rawValue == raw)
            #expect(PublicationState(rawValue: raw) == state)
        }
    }

    @Test("an experience round-trips with its grouping signals")
    func experienceRoundTrips() throws {
        let experience = Experience(
            userID: Identifier(),
            assetIDs: [Identifier(), Identifier()],
            startedAt: Self.now,
            endedAt: Self.now.addingTimeInterval(3600),
            centroid: Coordinate(latitude: 35.0, longitude: 139.0),
            title: "Lunch near the fish market",
            groupingSignals: [.gpsProximity, .timeProximity, .visualSimilarity]
        )
        let decoded = try Self.roundTrip(experience)
        #expect(decoded == experience)
        #expect(decoded.duration == 3600)
    }
}

/// Guards on `PlaceMatch`, which decides whether content may assert a venue as
/// fact. Getting this wrong means the app inventing a restaurant (§17.11).
@Suite("Place match confidence")
struct PlaceMatchTests {

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func match(
        confidence: Double,
        evidence: Set<PlaceMatch.Evidence>,
        confirmed: Bool = false,
        rejected: Bool = false
    ) -> PlaceMatch {
        PlaceMatch(
            experienceID: Identifier(),
            providerPlaceID: "p1",
            cachedName: "Somewhere",
            cachedAt: now,
            distanceMetres: 12,
            confidence: confidence,
            evidence: evidence,
            isUserConfirmed: confirmed,
            isUserRejected: rejected
        )
    }

    /// The brief is explicit: never assume the nearest restaurant is the right
    /// one. Proximity alone must never be enough to state a venue as fact.
    @Test("GPS proximity alone never licenses stating a venue as fact")
    func proximityAloneIsNotEnough() {
        let m = Self.match(confidence: 0.99, evidence: [.gpsProximity])
        #expect(!m.mayBeStatedAsFact)
    }

    @Test("high confidence with corroboration licenses a factual claim")
    func corroboratedHighConfidenceIsEnough() {
        let m = Self.match(confidence: 0.9, evidence: [.gpsProximity, .nameFoundInImageText])
        #expect(m.mayBeStatedAsFact)
    }

    @Test("corroboration without high confidence is not enough")
    func lowConfidenceIsNotEnough() {
        let m = Self.match(confidence: 0.5, evidence: [.nameFoundInImageText])
        #expect(!m.mayBeStatedAsFact)
    }

    @Test("user confirmation always licenses a factual claim")
    func userConfirmationWins() {
        let m = Self.match(confidence: 0.1, evidence: [], confirmed: true)
        #expect(m.mayBeStatedAsFact)
    }

    @Test("a user rejection overrides everything, including confirmation")
    func userRejectionOverridesAll() {
        let m = Self.match(
            confidence: 1.0,
            evidence: [.nameFoundInImageText, .userConfirmed],
            confirmed: true,
            rejected: true
        )
        #expect(!m.mayBeStatedAsFact)
    }

    @Test("confidence is clamped into 0...1")
    func confidenceClamped() {
        #expect(Self.match(confidence: 5.0, evidence: []).confidence == 1.0)
        #expect(Self.match(confidence: -3.0, evidence: []).confidence == 0.0)
    }

    /// Google Maps Platform grants no indefinite caching exception for display
    /// fields, so they must visibly expire.
    @Test("cached display fields expire after thirty days")
    func displayCacheExpires() {
        let m = Self.match(confidence: 0.9, evidence: [])
        #expect(!m.needsRefresh(asOf: Self.now.addingTimeInterval(29 * 86400)))
        #expect(m.needsRefresh(asOf: Self.now.addingTimeInterval(31 * 86400)))
    }
}
