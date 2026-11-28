import Foundation

/// What the backend currently holds for one asset on one device.
public struct RemoteIndexRecord: Sendable, Hashable {
    public let localIdentifier: String
    /// The model the stored vector came from.
    public let modelIdentifier: String
    /// When the backend last accepted an update for this asset.
    public let syncedAt: Date

    public init(localIdentifier: String, modelIdentifier: String, syncedAt: Date) {
        self.localIdentifier = localIdentifier
        self.modelIdentifier = modelIdentifier
        self.syncedAt = syncedAt
    }
}

/// The work needed to bring the backend in line with the device.
public struct IndexSyncPlan: Sendable, Hashable {
    /// Assets the backend is missing or holds a stale version of.
    public let toUpload: [String]
    /// Assets the backend holds that the device no longer has.
    public let toDeleteRemotely: [String]
    /// Assets already in step, reported so the UI can show a real denominator.
    public let alreadyInSync: Int

    public var hasWork: Bool { !toUpload.isEmpty || !toDeleteRemotely.isEmpty }
    public var totalOperations: Int { toUpload.count + toDeleteRemotely.count }

    /// Splits uploads into request-sized batches.
    ///
    /// A 20,000-row insert in one request would risk a gateway timeout and,
    /// worse, lose all of it on a retry. Batching bounds what a failure costs.
    public func uploadBatches(size: Int) -> [[String]] {
        guard size > 0, !toUpload.isEmpty else { return [] }
        return stride(from: 0, to: toUpload.count, by: size).map {
            Array(toUpload[$0..<min($0 + size, toUpload.count)])
        }
    }
}

/// Diffs the local index against the backend's.
///
/// The device is the source of truth: it is the only place that can see the
/// photo library. So this is a push, with deletions propagated — never a pull
/// that could overwrite local state with a stale server copy.
public enum IndexSyncPlanner {

    public static func plan(
        local: [IndexedAssetRecord],
        remote: [RemoteIndexRecord]
    ) -> IndexSyncPlan {
        let remoteByID = Dictionary(
            remote.map { ($0.localIdentifier, $0) },
            // A duplicate from the server is a bug there; keep the newest so we
            // compare against the most recent state rather than failing.
            uniquingKeysWith: { $0.syncedAt >= $1.syncedAt ? $0 : $1 }
        )

        var toUpload: [String] = []
        var alreadyInSync = 0
        var seenLocally = Set<String>()

        for record in local {
            guard seenLocally.insert(record.localIdentifier).inserted else { continue }

            guard let remoteRecord = remoteByID[record.localIdentifier] else {
                toUpload.append(record.localIdentifier)
                continue
            }

            if needsUpload(local: record, remote: remoteRecord) {
                toUpload.append(record.localIdentifier)
            } else {
                alreadyInSync += 1
            }
        }

        let toDeleteRemotely = Set(remote.map(\.localIdentifier))
            .subtracting(seenLocally)
            .sorted()

        return IndexSyncPlan(
            toUpload: toUpload,
            toDeleteRemotely: toDeleteRemotely,
            alreadyInSync: alreadyInSync
        )
    }

    private static func needsUpload(
        local: IndexedAssetRecord,
        remote: RemoteIndexRecord
    ) -> Bool {
        // A different model means the stored vector is not comparable with the
        // ones the device now produces, so it has to be replaced regardless of
        // timestamps.
        if local.modelIdentifier != remote.modelIdentifier { return true }

        // Re-embedded since the backend last saw it. Strictly greater, so a
        // clock that has not moved does not cause an upload loop.
        return local.indexedAt > remote.syncedAt
    }
}

/// Pushes index rows to the backend.
///
/// A protocol so the planner and its callers are testable with a fake. The
/// Supabase implementation lands when there is a project to point at; until
/// then `FakeIndexSyncing` in the tests is the only conformer, and
/// `ProviderSelector`'s rule keeps a mock from being mistaken for the real
/// thing once a credential exists.
public protocol IndexSyncing: Sendable {
    /// What the backend holds for this device.
    func remoteRecords() async throws -> [RemoteIndexRecord]

    /// Pushes embeddings and their metadata. Must be idempotent: a retry after
    /// a lost response has to be safe, which is why the backend keys rows on
    /// (device, local identifier) rather than inserting blindly.
    func upload(_ rows: [IndexSyncRow]) async throws

    /// Removes rows for assets no longer on the device.
    func deleteRemotely(localIdentifiers: [String]) async throws
}

/// One asset's worth of index data, as the backend receives it.
///
/// Note what is absent: any pixel data. This is the privacy boundary in
/// concrete form — a vector and some metadata, never an image. See
/// docs/ARCHITECTURE.md.
public struct IndexSyncRow: Sendable, Hashable {
    public let localIdentifier: String
    public let vector: [Float]
    public let modelIdentifier: String
    public let createdAt: Date?
    public let coordinate: Coordinate?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval?
    public let albumNames: [String]
    public let mediaKind: MediaKind
    public let sourceModificationDate: Date?
    public let indexedAt: Date

    public init(
        localIdentifier: String,
        vector: [Float],
        modelIdentifier: String,
        createdAt: Date? = nil,
        coordinate: Coordinate? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        duration: TimeInterval? = nil,
        albumNames: [String] = [],
        mediaKind: MediaKind = .image,
        sourceModificationDate: Date? = nil,
        indexedAt: Date
    ) {
        self.localIdentifier = localIdentifier
        self.vector = vector
        self.modelIdentifier = modelIdentifier
        self.createdAt = createdAt
        self.coordinate = coordinate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.albumNames = albumNames
        self.mediaKind = mediaKind
        self.sourceModificationDate = sourceModificationDate
        self.indexedAt = indexedAt
    }

    /// Rejects a vector that does not match the model's declared size.
    ///
    /// Checked before upload so a bad row fails here rather than as an opaque
    /// Postgres error about a vector dimension mismatch.
    public func hasValidVector(expectedDimensions: Int) -> Bool {
        vector.count == expectedDimensions && vector.allSatisfy { $0.isFinite }
    }
}
