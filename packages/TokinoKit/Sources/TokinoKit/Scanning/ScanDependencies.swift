import Foundation

/// Reads the device's photo library.
///
/// Exists so `ScanEngine` can be tested without PhotoKit, which is unavailable
/// on Linux and barely usable in a simulator. The iOS implementation wraps
/// `PHAsset`; tests use a fake.
public protocol PhotoLibraryReading: Sendable {
    /// Every asset currently visible to the app.
    ///
    /// Must not force an iCloud download or read pixel data — the brief forbids
    /// pulling the whole library down, and a 20,000-asset enumeration has to be
    /// cheap.
    func enumerateAssets() async throws -> [LibraryAssetSnapshot]

    /// A downsized derivative suitable for embedding.
    ///
    /// Never waits on a network fetch: the brief forbids pulling the library
    /// down from iCloud. An asset that is not local comes back as
    /// `.deferredToCloud` and is retried by a later scan.
    func thumbnail(for localIdentifier: String, maxPixelSize: Int) async throws -> ThumbnailOutcome

    /// PhotoKit's persistent change token, opaque to us.
    ///
    /// Stored in the checkpoint so the next run can ask the library only what
    /// changed. Nil when the platform cannot supply one, in which case the scan
    /// falls back to a full enumeration and diff — correct, just less efficient.
    func currentChangeToken() async -> Data?
}

/// What asking for a thumbnail produced.
///
/// Three cases rather than an optional, because the difference matters to the
/// user. PhotoKit has **no property** telling you in advance whether an asset's
/// data is on the device: the only documented way to find out is to request an
/// image with `isNetworkAccessAllowed = false` and inspect
/// `PHImageResultIsInCloudKey` in the result. So "this photo lives in iCloud"
/// is discovered here, during the scan, not during enumeration — which is why
/// `LibraryAssetSnapshot.isCloudOnly` is always false on iOS.
///
/// Conflating the cloud case with failure would tell someone their photos are
/// broken when they are merely not downloaded.
public enum ThumbnailOutcome: Sendable, Hashable {
    case available(Data)
    /// The asset exists but its data is only in iCloud. Not an error, and worth
    /// retrying once it has been downloaded.
    case deferredToCloud
    /// Genuinely unreadable: a corrupt file, an unsupported format, a revoked
    /// permission.
    case unavailable(reason: String)
}

/// Turns image bytes into an embedding.
public protocol ImageEmbedding: Sendable {
    // These three are `nonisolated` so an actor can conform. A real
    // implementation wraps a Core ML model and wants to be an actor — model
    // handles are not thread-safe — but these values are derived from
    // immutable configuration and need no isolation to read. Without this, the
    // conformance fails with "crosses into actor-isolated code".

    /// Identifies the model, so a later upgrade can re-index only stale rows.
    /// Written into `IndexedAssetRecord.modelIdentifier`.
    nonisolated var modelIdentifier: String { get }

    /// Expected output length. Checked against every result, because a
    /// mismatched vector reaching the store becomes an opaque database error
    /// far from its cause.
    nonisolated var dimensions: Int { get }

    /// The longest edge, in pixels, this model wants its input at.
    nonisolated var preferredInputPixelSize: Int { get }

    func embed(imageData: Data) async throws -> [Float]
}

/// A vector ready to persist.
public struct StoredEmbedding: Sendable, Hashable {
    public let localIdentifier: String
    public let vector: [Float]
    public let modelIdentifier: String
    /// The asset's modification date when embedded, so a later scan can tell
    /// whether the asset changed underneath us.
    public let sourceModificationDate: Date?
    public let embeddedAt: Date

    public init(
        localIdentifier: String,
        vector: [Float],
        modelIdentifier: String,
        sourceModificationDate: Date?,
        embeddedAt: Date
    ) {
        self.localIdentifier = localIdentifier
        self.vector = vector
        self.modelIdentifier = modelIdentifier
        self.sourceModificationDate = sourceModificationDate
        self.embeddedAt = embeddedAt
    }
}

/// Persists embeddings. SQLite on iOS, in-memory in tests.
public protocol EmbeddingStore: Sendable {
    /// What is already indexed, for the scan diff.
    func indexedRecords() async throws -> [IndexedAssetRecord]

    /// Writes a batch. Implementations should be atomic per batch so an
    /// interrupted scan leaves a consistent store.
    func store(_ embeddings: [StoredEmbedding]) async throws

    /// Drops records for assets no longer in the library.
    func remove(localIdentifiers: [String]) async throws
}

/// Persists scan progress across launches and process kills.
public protocol ScanCheckpointStore: Sendable {
    func load() async throws -> ScanCheckpoint?
    func save(_ checkpoint: ScanCheckpoint) async throws
    func clear() async throws
}

/// Supplies current device conditions to the gate.
///
/// A closure-like protocol rather than a value, because conditions change
/// during a long scan: the user unplugs the phone, battery drops, Wi-Fi comes
/// and goes. Re-read between batches.
public protocol DeviceConditionsProviding: Sendable {
    func currentConditions() async -> DeviceConditions
}

/// Receives progress updates during a scan.
///
/// Separate from the return value because a scan can run for minutes and the UI
/// — and `BGContinuedProcessingTask`'s system progress display — must update as
/// it goes. Apple's documentation notes the system prioritises terminating
/// continued-processing tasks showing minimal progress, so reporting honestly
/// is what keeps the task alive.
public protocol ScanProgressObserving: Sendable {
    func scanDidProgress(_ progress: ScanProgress) async
}

/// A progress observer that does nothing, for callers that only want the result.
public struct NullScanProgressObserver: ScanProgressObserving {
    public init() {}
    public func scanDidProgress(_ progress: ScanProgress) async {}
}
