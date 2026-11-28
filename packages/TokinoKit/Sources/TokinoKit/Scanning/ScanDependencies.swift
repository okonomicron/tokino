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
    /// Returns nil when the asset is not available locally, rather than waiting
    /// on a network fetch. The caller records it as skipped and moves on.
    func thumbnailData(for localIdentifier: String, maxPixelSize: Int) async throws -> Data?

    /// PhotoKit's persistent change token, opaque to us.
    ///
    /// Stored in the checkpoint so the next run can ask the library only what
    /// changed. Nil when the platform cannot supply one, in which case the scan
    /// falls back to a full enumeration and diff — correct, just less efficient.
    func currentChangeToken() async -> Data?
}

/// Turns image bytes into an embedding.
public protocol ImageEmbedding: Sendable {
    /// Identifies the model, so a later upgrade can re-index only stale rows.
    /// Written into `IndexedAssetRecord.modelIdentifier`.
    var modelIdentifier: String { get }

    /// Expected output length. Checked against every result, because a
    /// mismatched vector reaching the store becomes an opaque database error
    /// far from its cause.
    var dimensions: Int { get }

    /// The longest edge, in pixels, this model wants its input at.
    var preferredInputPixelSize: Int { get }

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
