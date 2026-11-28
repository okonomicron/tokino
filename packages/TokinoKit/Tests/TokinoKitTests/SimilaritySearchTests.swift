import Foundation
import Testing
@testable import TokinoKit

@Suite("Similarity search")
struct SimilaritySearchTests {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let dimensions = 8

    /// A one-hot vector, so expected rankings are obvious by construction
    /// rather than requiring a mental dot product.
    static func oneHot(_ index: Int, scale: Float = 1) -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        vector[index] = scale
        return vector
    }

    static func candidate(
        _ id: Identifier<PhotoAsset>,
        vector: [Float],
        createdAt: Date? = nil,
        coordinate: Coordinate? = nil,
        albums: [String] = [],
        kind: MediaKind = .image,
        quality: Double = 1.0,
        excluded: Bool = false
    ) -> SearchCandidate {
        SearchCandidate(
            assetID: id,
            vector: vector,
            createdAt: createdAt,
            coordinate: coordinate,
            albumNames: albums,
            mediaKind: kind,
            quality: quality,
            isExcluded: excluded
        )
    }

    // MARK: - Vector maths

    @Test("normalising yields unit length")
    func normalizationYieldsUnitLength() {
        let normalized = SimilaritySearch.normalized([3, 4, 0, 0, 0, 0, 0, 0])
        let magnitude = normalized.reduce(0) { $0 + $1 * $1 }.squareRoot()
        #expect(abs(magnitude - 1) < 1e-6)
        #expect(abs(normalized[0] - 0.6) < 1e-6)
        #expect(abs(normalized[1] - 0.8) < 1e-6)
    }

    /// A zero vector has no direction, and dividing by its magnitude would
    /// produce NaNs that silently poison every later comparison.
    @Test("a zero vector normalises to itself rather than NaN")
    func zeroVectorIsSafe() {
        let zero = [Float](repeating: 0, count: Self.dimensions)
        let normalized = SimilaritySearch.normalized(zero)
        #expect(normalized == zero)
        #expect(!normalized.contains { $0.isNaN })
        #expect(SimilaritySearch.cosineSimilarity(zero, Self.oneHot(0)) == 0)
    }

    @Test("cosine similarity is 1 for parallel and 0 for orthogonal vectors")
    func cosineBounds() {
        #expect(abs(SimilaritySearch.cosineSimilarity(Self.oneHot(0), Self.oneHot(0)) - 1) < 1e-6)
        #expect(abs(SimilaritySearch.cosineSimilarity(Self.oneHot(0), Self.oneHot(1))) < 1e-6)
    }

    @Test("cosine similarity is -1 for opposed vectors")
    func cosineOpposed() {
        let similarity = SimilaritySearch.cosineSimilarity(
            Self.oneHot(0, scale: 1),
            Self.oneHot(0, scale: -1)
        )
        #expect(abs(similarity + 1) < 1e-6)
    }

    /// Magnitude must not affect the score, or brighter or more "confident"
    /// embeddings would outrank more relevant ones.
    @Test("magnitude does not affect the score")
    func magnitudeIrrelevant() {
        let small = SimilaritySearch.cosineSimilarity(Self.oneHot(0, scale: 0.01), Self.oneHot(0))
        let large = SimilaritySearch.cosineSimilarity(Self.oneHot(0, scale: 100), Self.oneHot(0))
        #expect(abs(small - large) < 1e-5)
    }

    /// A dimension mismatch means the vectors came from different models.
    @Test("mismatched dimensions score zero rather than trapping")
    func mismatchedDimensionsAreSafe() {
        #expect(SimilaritySearch.cosineSimilarity([1, 0], [1, 0, 0]) == 0)
        #expect(SimilaritySearch.dot([1, 0], [1, 0, 0]) == 0)
    }

    // MARK: - Ranking

    @Test("results come back in descending similarity order")
    func rankingOrder() {
        let query = Self.oneHot(0)
        let near = Identifier<PhotoAsset>.deterministic(from: "near")
        let middle = Identifier<PhotoAsset>.deterministic(from: "middle")
        let far = Identifier<PhotoAsset>.deterministic(from: "far")

        let candidates = [
            Self.candidate(far, vector: Self.oneHot(1)),
            Self.candidate(near, vector: Self.oneHot(0)),
            // Equal parts dimension 0 and 1, so it sits between the two.
            Self.candidate(middle, vector: [1, 1, 0, 0, 0, 0, 0, 0]),
        ]

        let results = SimilaritySearch.rank(query: query, candidates: candidates)
        #expect(results.map(\.assetID) == [near, middle, far])
        #expect(results[0].score > results[1].score)
        #expect(results[1].score > results[2].score)
    }

    @Test("the limit is honoured")
    func limitHonoured() {
        let candidates = (0..<20).map {
            Self.candidate(.deterministic(from: "a\($0)"), vector: Self.oneHot($0 % Self.dimensions))
        }
        #expect(SimilaritySearch.rank(query: Self.oneHot(0), candidates: candidates, limit: 5).count == 5)
        #expect(SimilaritySearch.rank(query: Self.oneHot(0), candidates: candidates, limit: 0).isEmpty)
    }

    @Test("an empty candidate set or empty query yields no results")
    func emptyInputs() {
        #expect(SimilaritySearch.rank(query: Self.oneHot(0), candidates: []).isEmpty)
        #expect(
            SimilaritySearch.rank(
                query: [],
                candidates: [Self.candidate(.deterministic(from: "a"), vector: Self.oneHot(0))]
            ).isEmpty
        )
    }

    /// An unstable order would make the results grid reshuffle on every
    /// keystroke, which reads as a bug to the user.
    @Test("ties break deterministically so results do not reshuffle")
    func tiesAreStable() {
        let ids = (0..<6).map { Identifier<PhotoAsset>.deterministic(from: "tie\($0)") }
        // Every candidate is identical, so every score ties.
        let candidates = ids.map { Self.candidate($0, vector: Self.oneHot(0)) }

        let first = SimilaritySearch.rank(query: Self.oneHot(0), candidates: candidates)
        let shuffled = SimilaritySearch.rank(
            query: Self.oneHot(0),
            candidates: candidates.shuffled()
        )
        #expect(first.map(\.assetID) == shuffled.map(\.assetID))
    }

    /// Vectors from a superseded model are not comparable, so they must be
    /// absent rather than scored zero and shown at the bottom.
    @Test("candidates from another model are skipped, not ranked last")
    func wrongDimensionCandidatesSkipped() {
        let good = Identifier<PhotoAsset>.deterministic(from: "good")
        let stale = Identifier<PhotoAsset>.deterministic(from: "stale")
        let candidates = [
            Self.candidate(good, vector: Self.oneHot(0)),
            Self.candidate(stale, vector: [Float](repeating: 1, count: 4)),
        ]

        let results = SimilaritySearch.rank(query: Self.oneHot(0), candidates: candidates)
        #expect(results.map(\.assetID) == [good])
    }

    // MARK: - Criteria filtering

    @Test("a user-excluded asset never appears, whatever its score")
    func userExclusionWins() {
        let excluded = Identifier<PhotoAsset>.deterministic(from: "excluded")
        let candidates = [Self.candidate(excluded, vector: Self.oneHot(0), excluded: true)]

        let results = SimilaritySearch.search(query: Self.oneHot(0), candidates: candidates)
        #expect(results.isEmpty)
        #expect(
            AssetCriteriaFilter.rejection(for: candidates[0], criteria: .init()) == .excludedByUser
        )
    }

    @Test("media kind is respected")
    func mediaKindFilter() {
        let video = Self.candidate(.deterministic(from: "v"), vector: Self.oneHot(0), kind: .video)
        #expect(
            AssetCriteriaFilter.rejection(
                for: video,
                criteria: PhotoSelectionCriteria(mediaKinds: [.image])
            ) == .mediaKindNotWanted
        )
        #expect(
            AssetCriteriaFilter.matches(video, criteria: PhotoSelectionCriteria(mediaKinds: [.video]))
        )
    }

    @Test("date bounds are respected at both ends")
    func dateFilter() {
        let subject = Self.candidate(
            .deterministic(from: "d"),
            vector: Self.oneHot(0),
            createdAt: Self.t0
        )
        #expect(
            AssetCriteriaFilter.rejection(
                for: subject,
                criteria: PhotoSelectionCriteria(earliestDate: Self.t0.addingTimeInterval(60))
            ) == .beforeEarliestDate
        )
        #expect(
            AssetCriteriaFilter.rejection(
                for: subject,
                criteria: PhotoSelectionCriteria(latestDate: Self.t0.addingTimeInterval(-60))
            ) == .afterLatestDate
        )
        #expect(
            AssetCriteriaFilter.matches(
                subject,
                criteria: PhotoSelectionCriteria(
                    earliestDate: Self.t0.addingTimeInterval(-60),
                    latestDate: Self.t0.addingTimeInterval(60)
                )
            )
        )
    }

    /// Being strict keeps "my 2019 trip" from quietly including undated photos.
    @Test("an undated asset is excluded when a date filter is active")
    func undatedAssetExcludedByDateFilter() {
        let undated = Self.candidate(.deterministic(from: "u"), vector: Self.oneHot(0))
        #expect(
            AssetCriteriaFilter.rejection(
                for: undated,
                criteria: PhotoSelectionCriteria(earliestDate: Self.t0)
            ) == .missingDateButDateFiltered
        )
        // With no date filter it is admitted.
        #expect(AssetCriteriaFilter.matches(undated, criteria: .init()))
    }

    @Test("the radius filter uses real distance")
    func radiusFilter() {
        let tokyoStation = Coordinate(latitude: 35.6812, longitude: 139.7671)
        let tsukiji = Coordinate(latitude: 35.6654, longitude: 139.7707)  // ~1.8 km away
        let osaka = Coordinate(latitude: 34.7024, longitude: 135.4959)

        let near = Self.candidate(.deterministic(from: "n"), vector: Self.oneHot(0), coordinate: tsukiji)
        let far = Self.candidate(.deterministic(from: "f"), vector: Self.oneHot(0), coordinate: osaka)

        let criteria = PhotoSelectionCriteria(nearCoordinate: tokyoStation, radiusMetres: 5_000)
        #expect(AssetCriteriaFilter.matches(near, criteria: criteria))
        #expect(AssetCriteriaFilter.rejection(for: far, criteria: criteria) == .outsideRadius)
    }

    @Test("an asset with no coordinate is excluded when a geo filter is active")
    func ungeotaggedExcludedByGeoFilter() {
        let subject = Self.candidate(.deterministic(from: "g"), vector: Self.oneHot(0))
        let criteria = PhotoSelectionCriteria(
            nearCoordinate: Coordinate(latitude: 35, longitude: 139),
            radiusMetres: 1_000
        )
        #expect(
            AssetCriteriaFilter.rejection(for: subject, criteria: criteria)
                == .missingCoordinateButGeoFiltered
        )
    }

    /// A radius without a centre, or a centre without a radius, is not a filter.
    @Test("a half-specified geo filter is ignored")
    func halfSpecifiedGeoFilterIgnored() {
        let subject = Self.candidate(.deterministic(from: "h"), vector: Self.oneHot(0))
        #expect(
            AssetCriteriaFilter.matches(
                subject,
                criteria: PhotoSelectionCriteria(radiusMetres: 100)
            )
        )
        #expect(
            AssetCriteriaFilter.matches(
                subject,
                criteria: PhotoSelectionCriteria(
                    nearCoordinate: Coordinate(latitude: 1, longitude: 1)
                )
            )
        )
    }

    @Test("membership of any one required album is enough")
    func requiredAlbums() {
        let subject = Self.candidate(
            .deterministic(from: "a"),
            vector: Self.oneHot(0),
            albums: ["Hokkaido", "Favourites"]
        )
        #expect(
            AssetCriteriaFilter.matches(
                subject,
                criteria: PhotoSelectionCriteria(requiredAlbumNames: ["Hokkaido", "Kyushu"])
            )
        )
        #expect(
            AssetCriteriaFilter.rejection(
                for: subject,
                criteria: PhotoSelectionCriteria(requiredAlbumNames: ["Kyushu"])
            ) == .notInRequiredAlbum
        )
    }

    @Test("one excluded album is enough to reject")
    func excludedAlbums() {
        let subject = Self.candidate(
            .deterministic(from: "a"),
            vector: Self.oneHot(0),
            albums: ["Trip", "Screenshots"]
        )
        #expect(
            AssetCriteriaFilter.rejection(
                for: subject,
                criteria: PhotoSelectionCriteria(excludedAlbumNames: ["Screenshots"])
            ) == .inExcludedAlbum
        )
    }

    @Test("the quality floor is applied")
    func qualityFloor() {
        let blurry = Self.candidate(.deterministic(from: "b"), vector: Self.oneHot(0), quality: 0.1)
        #expect(
            AssetCriteriaFilter.rejection(
                for: blurry,
                criteria: PhotoSelectionCriteria(minimumQuality: 0.5)
            ) == .belowQualityFloor
        )
        #expect(
            AssetCriteriaFilter.matches(
                blurry,
                criteria: PhotoSelectionCriteria(minimumQuality: 0.05)
            )
        )
    }

    /// Rejection reasons exist so an empty result set can be explained to the
    /// user rather than shown as a blank grid.
    @Test("every rejection reason is reachable")
    func everyRejectionReasonIsReachable() {
        var seen = Set<AssetCriteriaFilter.Rejection>()
        let base = Self.oneHot(0)

        seen.insert(.excludedByUser)
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(.deterministic(from: "1"), vector: base, excluded: true),
            criteria: .init()) { seen.insert(r) }
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(.deterministic(from: "2"), vector: base, kind: .video),
            criteria: PhotoSelectionCriteria(mediaKinds: [.image])) { seen.insert(r) }
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(.deterministic(from: "3"), vector: base, createdAt: Self.t0),
            criteria: PhotoSelectionCriteria(earliestDate: Self.t0.addingTimeInterval(1))) { seen.insert(r) }
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(.deterministic(from: "4"), vector: base, createdAt: Self.t0),
            criteria: PhotoSelectionCriteria(latestDate: Self.t0.addingTimeInterval(-1))) { seen.insert(r) }
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(.deterministic(from: "5"), vector: base),
            criteria: PhotoSelectionCriteria(earliestDate: Self.t0)) { seen.insert(r) }
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(
                .deterministic(from: "6"), vector: base,
                coordinate: Coordinate(latitude: 0, longitude: 0)),
            criteria: PhotoSelectionCriteria(
                nearCoordinate: Coordinate(latitude: 35, longitude: 139), radiusMetres: 10)) { seen.insert(r) }
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(.deterministic(from: "7"), vector: base),
            criteria: PhotoSelectionCriteria(
                nearCoordinate: Coordinate(latitude: 35, longitude: 139), radiusMetres: 10)) { seen.insert(r) }
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(.deterministic(from: "8"), vector: base, albums: ["X"]),
            criteria: PhotoSelectionCriteria(requiredAlbumNames: ["Y"])) { seen.insert(r) }
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(.deterministic(from: "9"), vector: base, albums: ["X"]),
            criteria: PhotoSelectionCriteria(excludedAlbumNames: ["X"])) { seen.insert(r) }
        if let r = AssetCriteriaFilter.rejection(
            for: Self.candidate(.deterministic(from: "10"), vector: base, quality: 0),
            criteria: PhotoSelectionCriteria(minimumQuality: 0.5)) { seen.insert(r) }

        #expect(
            seen == Set(AssetCriteriaFilter.Rejection.allCases),
            "unreachable rejection reasons: \(Set(AssetCriteriaFilter.Rejection.allCases).subtracting(seen))"
        )
    }

    // MARK: - Combined search

    @Test("search filters before ranking")
    func searchFiltersThenRanks() {
        let keep = Identifier<PhotoAsset>.deterministic(from: "keep")
        let drop = Identifier<PhotoAsset>.deterministic(from: "drop")

        let candidates = [
            // The best match, but excluded by the user.
            Self.candidate(drop, vector: Self.oneHot(0), excluded: true),
            // A worse match that is admissible.
            Self.candidate(keep, vector: [1, 1, 0, 0, 0, 0, 0, 0]),
        ]

        let results = SimilaritySearch.search(query: Self.oneHot(0), candidates: candidates)
        #expect(results.map(\.assetID) == [keep])
    }

    @Test("a realistic index ranks the planted match first")
    func realisticIndexRanksPlantedMatch() {
        // 500 assets of random-ish directions plus one planted exact match, to
        // check ranking holds at a size where an off-by-one in sorting shows up.
        var candidates: [SearchCandidate] = []
        for index in 0..<500 {
            var vector = [Float](repeating: 0, count: Self.dimensions)
            vector[index % Self.dimensions] = 0.5
            vector[(index + 3) % Self.dimensions] = 0.4
            candidates.append(
                Self.candidate(.deterministic(from: "bulk\(index)"), vector: vector)
            )
        }
        let planted = Identifier<PhotoAsset>.deterministic(from: "planted")
        candidates.append(Self.candidate(planted, vector: Self.oneHot(5)))

        let results = SimilaritySearch.rank(
            query: Self.oneHot(5),
            candidates: candidates.shuffled(),
            limit: 3
        )
        #expect(results.first?.assetID == planted)
        #expect(abs((results.first?.score ?? 0) - 1) < 1e-6)
    }
}
