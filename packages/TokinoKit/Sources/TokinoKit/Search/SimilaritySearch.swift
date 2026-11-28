import Foundation

/// A photo as the search index sees it: its embedding plus the metadata needed
/// to apply a strategy's selection criteria.
///
/// Deliberately not `PhotoAsset`. Search touches every indexed asset, so it
/// carries only the fields filtering and ranking actually read.
public struct SearchCandidate: Sendable {
    public let assetID: Identifier<PhotoAsset>
    /// The embedding. Expected to be L2-normalised already — see
    /// `SimilaritySearch.rank(query:candidates:limit:)`.
    public let vector: [Float]
    public let createdAt: Date?
    public let coordinate: Coordinate?
    public let albumNames: [String]
    public let mediaKind: MediaKind
    /// 0...1 photographic quality from on-device assessment.
    public let quality: Double
    /// Set when the user has excluded this asset from all strategies.
    public let isExcluded: Bool

    public init(
        assetID: Identifier<PhotoAsset>,
        vector: [Float],
        createdAt: Date? = nil,
        coordinate: Coordinate? = nil,
        albumNames: [String] = [],
        mediaKind: MediaKind = .image,
        quality: Double = 1.0,
        isExcluded: Bool = false
    ) {
        self.assetID = assetID
        self.vector = vector
        self.createdAt = createdAt
        self.coordinate = coordinate
        self.albumNames = albumNames
        self.mediaKind = mediaKind
        self.quality = quality
        self.isExcluded = isExcluded
    }
}

/// One ranked hit.
public struct SearchResult: Sendable, Hashable {
    public let assetID: Identifier<PhotoAsset>
    /// Cosine similarity in -1...1. Higher is closer.
    public let score: Float

    public init(assetID: Identifier<PhotoAsset>, score: Float) {
        self.assetID = assetID
        self.score = score
    }
}

/// Decides which assets a strategy's criteria admit.
///
/// Separate from ranking so that a wrong result can be attributed: either the
/// filter excluded something it should not have, or the scoring mis-ranked it.
/// Debugging a combined implementation is much harder.
public enum AssetCriteriaFilter {

    /// Why a candidate was rejected. Returned rather than a bare `Bool` so the
    /// UI can explain an empty result set — "no photos in that date range" is
    /// far more useful than "no results".
    public enum Rejection: String, Sendable, Hashable, CaseIterable {
        case excludedByUser
        case mediaKindNotWanted
        case beforeEarliestDate
        case afterLatestDate
        case missingDateButDateFiltered
        case outsideRadius
        case missingCoordinateButGeoFiltered
        case notInRequiredAlbum
        case inExcludedAlbum
        case belowQualityFloor
    }

    /// Nil when the candidate is admitted.
    public static func rejection(
        for candidate: SearchCandidate,
        criteria: PhotoSelectionCriteria
    ) -> Rejection? {
        // The user's explicit exclusion outranks everything.
        if candidate.isExcluded { return .excludedByUser }

        if !criteria.mediaKinds.contains(candidate.mediaKind) { return .mediaKindNotWanted }

        if criteria.earliestDate != nil || criteria.latestDate != nil {
            // A date filter cannot be satisfied by an asset with no date. Being
            // strict here keeps "my 2019 trip" from including undated photos.
            guard let createdAt = candidate.createdAt else { return .missingDateButDateFiltered }
            if let earliest = criteria.earliestDate, createdAt < earliest {
                return .beforeEarliestDate
            }
            if let latest = criteria.latestDate, createdAt > latest { return .afterLatestDate }
        }

        if let centre = criteria.nearCoordinate, let radius = criteria.radiusMetres {
            guard let coordinate = candidate.coordinate else {
                return .missingCoordinateButGeoFiltered
            }
            // Reuses Coordinate.distance(to:) rather than a second haversine.
            if coordinate.distance(to: centre) > radius { return .outsideRadius }
        }

        if !criteria.requiredAlbumNames.isEmpty {
            // Membership of any one required album is enough.
            let required = Set(criteria.requiredAlbumNames)
            guard candidate.albumNames.contains(where: required.contains) else {
                return .notInRequiredAlbum
            }
        }

        if !criteria.excludedAlbumNames.isEmpty {
            let excluded = Set(criteria.excludedAlbumNames)
            if candidate.albumNames.contains(where: excluded.contains) { return .inExcludedAlbum }
        }

        if candidate.quality < criteria.minimumQuality { return .belowQualityFloor }

        return nil
    }

    public static func matches(
        _ candidate: SearchCandidate,
        criteria: PhotoSelectionCriteria
    ) -> Bool {
        rejection(for: candidate, criteria: criteria) == nil
    }

    public static func apply(
        to candidates: [SearchCandidate],
        criteria: PhotoSelectionCriteria
    ) -> [SearchCandidate] {
        candidates.filter { matches($0, criteria: criteria) }
    }
}

/// Ranks candidates by cosine similarity to a query embedding.
///
/// Brute force, deliberately. At one user's scale — tens of thousands of
/// 512-dimension vectors — a full scan is a few tens of milliseconds and is
/// exact. An approximate index would add a dependency, a build step and recall
/// error to solve a problem we do not have. Revisit if profiling on a real
/// library says otherwise.
public enum SimilaritySearch {

    /// L2-normalises a vector so that a dot product equals cosine similarity.
    ///
    /// Returns the input unchanged when its magnitude is zero, since there is no
    /// meaningful direction to normalise to and dividing would produce NaNs that
    /// poison every later comparison.
    public static func normalized(_ vector: [Float]) -> [Float] {
        var sumOfSquares: Float = 0
        for value in vector { sumOfSquares += value * value }
        guard sumOfSquares > 0 else { return vector }
        let inverseMagnitude = 1 / sumOfSquares.squareRoot()
        return vector.map { $0 * inverseMagnitude }
    }

    /// Cosine similarity, normalising both inputs.
    ///
    /// Returns 0 for mismatched lengths rather than trapping: a dimension
    /// mismatch means one side came from a different model, and a zero score
    /// drops it to the bottom of the ranking instead of crashing a search.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return dot(normalized(a), normalized(b))
    }

    /// Dot product of two vectors assumed already normalised.
    public static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var total: Float = 0
        for index in a.indices { total += a[index] * b[index] }
        return total
    }

    /// Top `limit` candidates by similarity to `query`.
    ///
    /// Both the query and each candidate vector are normalised here, so callers
    /// need not pre-normalise. Candidates whose dimensions do not match the
    /// query are skipped rather than scored as zero: they are from a superseded
    /// model and do not belong in results at all.
    ///
    /// Ties break on asset identifier so results are stable between runs. An
    /// unstable order would make the UI reshuffle on every keystroke.
    public static func rank(
        query: [Float],
        candidates: [SearchCandidate],
        limit: Int = 50
    ) -> [SearchResult] {
        guard limit > 0, !query.isEmpty else { return [] }
        let normalizedQuery = normalized(query)

        var scored: [SearchResult] = []
        scored.reserveCapacity(min(candidates.count, limit * 4))

        for candidate in candidates {
            guard candidate.vector.count == normalizedQuery.count else { continue }
            let score = dot(normalizedQuery, normalized(candidate.vector))
            scored.append(SearchResult(assetID: candidate.assetID, score: score))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.assetID.rawValue.uuidString < rhs.assetID.rawValue.uuidString
        }
        return Array(scored.prefix(limit))
    }

    /// Filters by criteria, then ranks. The ordinary entry point for a search.
    public static func search(
        query: [Float],
        candidates: [SearchCandidate],
        criteria: PhotoSelectionCriteria = .init(),
        limit: Int = 50
    ) -> [SearchResult] {
        rank(
            query: query,
            candidates: AssetCriteriaFilter.apply(to: candidates, criteria: criteria),
            limit: limit
        )
    }
}

/// Explains why a search returned nothing.
///
/// Three quite different situations produce an empty grid, and only one of them
/// means "try different words":
///
/// - nothing has been indexed yet,
/// - everything was filtered out by the strategy's criteria,
/// - photos were searchable but none matched well enough.
///
/// Deciding which applies is logic, so it lives here and is tested on Linux.
/// Turning the answer into a sentence is presentation and stays in the UI.
public enum EmptyResultDiagnosis: Sendable, Hashable {
    /// No candidates at all; the library has not been indexed.
    case nothingIndexed
    /// Candidates existed but every one was filtered out. Carries the reason
    /// that accounted for the most of them, since listing all of them is noise.
    case everythingFiltered(dominantReason: AssetCriteriaFilter.Rejection)
    /// Photos were searchable and simply did not match.
    case noGoodMatch

    /// Diagnoses an empty result set.
    ///
    /// - Parameters:
    ///   - candidates: every candidate considered, before filtering.
    ///   - admitted: those the criteria allowed through.
    public static func diagnose(
        candidates: [SearchCandidate],
        admitted: [SearchCandidate],
        criteria: PhotoSelectionCriteria
    ) -> EmptyResultDiagnosis {
        if candidates.isEmpty { return .nothingIndexed }
        if !admitted.isEmpty { return .noGoodMatch }

        var counts: [AssetCriteriaFilter.Rejection: Int] = [:]
        for candidate in candidates {
            if let rejection = AssetCriteriaFilter.rejection(for: candidate, criteria: criteria) {
                counts[rejection, default: 0] += 1
            }
        }

        // Ties break on the reason's raw value so the message is stable
        // between runs rather than flipping between two equally common causes.
        let dominant = counts
            .sorted { lhs, rhs in
                lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key.rawValue < rhs.key.rawValue
            }
            .first?.key

        guard let dominant else { return .noGoodMatch }
        return .everythingFiltered(dominantReason: dominant)
    }
}
