import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable, Hashable {
    case image
    case video
}

/// A geographic point from photo metadata.
public struct Coordinate: Sendable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Great-circle distance in metres. Used by experience grouping (M3) to
    /// decide whether two photos were taken in the same place.
    public func distance(to other: Coordinate) -> Double {
        let earthRadius = 6_371_000.0
        let lat1 = latitude * .pi / 180
        let lat2 = other.latitude * .pi / 180
        let deltaLat = (other.latitude - latitude) * .pi / 180
        let deltaLon = (other.longitude - longitude) * .pi / 180

        let a = sin(deltaLat / 2) * sin(deltaLat / 2)
            + cos(lat1) * cos(lat2) * sin(deltaLon / 2) * sin(deltaLon / 2)
        return earthRadius * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

/// An indexed photo or video from the user's library.
///
/// This is metadata only — deliberately no pixel data and no file path. The
/// original stays in the user's library untouched (§17.5), and the privacy
/// boundary (docs/ARCHITECTURE.md) permits only metadata and embeddings to leave
/// the device.
public struct PhotoAsset: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<PhotoAsset>
    /// PhotoKit's `localIdentifier`. Stable per device+library, so it is the
    /// dedupe key for incremental scanning, and is scoped per device rather than
    /// per user.
    public let localIdentifier: String
    public let deviceID: Identifier<Device>
    public let mediaKind: MediaKind
    public let createdAt: Date?
    public let coordinate: Coordinate?
    public let pixelWidth: Int
    public let pixelHeight: Int
    /// Video duration; nil for stills.
    public let duration: TimeInterval?
    /// Album names the asset belongs to, where PhotoKit grants access.
    public let albumNames: [String]
    /// True when PhotoKit reports the asset is not downloaded locally. Such
    /// assets are skipped rather than forcing an iCloud download (§2.2).
    public let isCloudOnly: Bool
    /// When we last indexed it, so a modified asset can be re-indexed.
    public let indexedAt: Date?
    /// Set when the user excludes this asset from all strategies (§2.2 privacy).
    public let isExcluded: Bool

    public init(
        id: Identifier<PhotoAsset> = Identifier(),
        localIdentifier: String,
        deviceID: Identifier<Device>,
        mediaKind: MediaKind,
        createdAt: Date? = nil,
        coordinate: Coordinate? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval? = nil,
        albumNames: [String] = [],
        isCloudOnly: Bool = false,
        indexedAt: Date? = nil,
        isExcluded: Bool = false
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.deviceID = deviceID
        self.mediaKind = mediaKind
        self.createdAt = createdAt
        self.coordinate = coordinate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.albumNames = albumNames
        self.isCloudOnly = isCloudOnly
        self.indexedAt = indexedAt
        self.isExcluded = isExcluded
    }

    public var aspectRatio: Double {
        pixelHeight == 0 ? 0 : Double(pixelWidth) / Double(pixelHeight)
    }

    /// Whether this asset is a candidate for content. Cloud-only assets have no
    /// embedding yet, and excluded ones are off limits by user instruction.
    public var isEligibleForContent: Bool {
        !isExcluded && !isCloudOnly && indexedAt != nil
    }
}

/// A device whose library we index. Separate from User because one user may
/// index more than one device, and `localIdentifier` only means something
/// within a single device's library.
public struct Device: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<Device>
    public let userID: Identifier<User>
    public let name: String
    public let model: String
    public let lastSeenAt: Date

    public init(
        id: Identifier<Device> = Identifier(),
        userID: Identifier<User>,
        name: String,
        model: String,
        lastSeenAt: Date
    ) {
        self.id = id
        self.userID = userID
        self.name = name
        self.model = model
        self.lastSeenAt = lastSeenAt
    }
}

public struct User: Sendable, Hashable, Codable, Identifiable {
    public let id: Identifier<User>
    public let email: String
    public let createdAt: Date

    public init(id: Identifier<User>, email: String, createdAt: Date) {
        self.id = id
        self.email = email
        self.createdAt = createdAt
    }
}

/// A semantic vector for one asset, produced on-device.
///
/// 512 dimensions matches MobileCLIP-S2's image encoder. The vector, not the
/// image, is what syncs to Postgres — that is the privacy boundary, and it is
/// what lets the backend reason about the library while the phone is asleep.
public struct PhotoEmbedding: Sendable, Hashable, Codable {
    public static let dimensions = 512

    public let assetID: Identifier<PhotoAsset>
    public let vector: [Float]
    /// Which model produced it, so a model upgrade can re-index only what it
    /// must rather than the whole library.
    public let modelIdentifier: String
    public let createdAt: Date

    public init(
        assetID: Identifier<PhotoAsset>,
        vector: [Float],
        modelIdentifier: String,
        createdAt: Date
    ) {
        self.assetID = assetID
        self.vector = vector
        self.modelIdentifier = modelIdentifier
        self.createdAt = createdAt
    }

    /// Rejects a wrong-sized vector rather than letting it reach pgvector, where
    /// it would fail as an opaque database error far from the cause.
    public var hasValidDimensions: Bool {
        vector.count == Self.dimensions
    }
}
