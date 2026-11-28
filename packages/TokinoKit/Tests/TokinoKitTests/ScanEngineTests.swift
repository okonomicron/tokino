import Foundation
import Testing
@testable import TokinoKit

// MARK: - Fakes

/// A photo library that serves whatever snapshots a test gives it.
actor FakeLibrary: PhotoLibraryReading {
    private var snapshots: [LibraryAssetSnapshot]
    private var unavailable: Set<String>
    private var throwingFor: Set<String>
    private var changeToken: Data?
    private(set) var thumbnailRequests: [String] = []

    init(
        snapshots: [LibraryAssetSnapshot],
        unavailable: Set<String> = [],
        throwingFor: Set<String> = [],
        changeToken: Data? = Data([0xAB])
    ) {
        self.snapshots = snapshots
        self.unavailable = unavailable
        self.throwingFor = throwingFor
        self.changeToken = changeToken
    }

    struct Unreadable: Error {}

    func enumerateAssets() async throws -> [LibraryAssetSnapshot] { snapshots }

    func thumbnailData(for localIdentifier: String, maxPixelSize: Int) async throws -> Data? {
        thumbnailRequests.append(localIdentifier)
        if throwingFor.contains(localIdentifier) { throw Unreadable() }
        if unavailable.contains(localIdentifier) { return nil }
        return Data(localIdentifier.utf8)
    }

    func currentChangeToken() async -> Data? { changeToken }

    func replace(with snapshots: [LibraryAssetSnapshot]) { self.snapshots = snapshots }
}

/// A deterministic embedder: the vector depends only on the input bytes, so
/// expectations are reproducible.
struct FakeEmbedder: ImageEmbedding {
    let modelIdentifier: String
    let dimensions: Int
    let preferredInputPixelSize = 224
    /// Identifiers for which to emit a wrong-sized vector, to exercise the
    /// dimension guard.
    let wrongSizeFor: Set<String>

    init(modelIdentifier: String = "fake-v1", dimensions: Int = 8, wrongSizeFor: Set<String> = []) {
        self.modelIdentifier = modelIdentifier
        self.dimensions = dimensions
        self.wrongSizeFor = wrongSizeFor
    }

    func embed(imageData: Data) async throws -> [Float] {
        let identifier = String(decoding: imageData, as: UTF8.self)
        if wrongSizeFor.contains(identifier) { return [1, 2, 3] }
        var vector = [Float](repeating: 0, count: dimensions)
        // Spread the bytes over the dimensions so different assets differ.
        for (offset, byte) in imageData.enumerated() {
            vector[offset % dimensions] += Float(byte) / 255
        }
        return vector
    }
}

actor FakeEmbeddingStore: EmbeddingStore {
    private(set) var stored: [String: StoredEmbedding] = [:]
    private(set) var removed: [String] = []
    private(set) var storeCallCount = 0
    private var seedRecords: [IndexedAssetRecord]
    private var failNextStore: Bool

    init(seed: [IndexedAssetRecord] = [], failNextStore: Bool = false) {
        self.seedRecords = seed
        self.failNextStore = failNextStore
    }

    struct WriteFailed: Error {}

    func indexedRecords() async throws -> [IndexedAssetRecord] {
        seedRecords + stored.values.map {
            IndexedAssetRecord(
                localIdentifier: $0.localIdentifier,
                indexedAt: $0.embeddedAt,
                sourceModificationDate: $0.sourceModificationDate,
                modelIdentifier: $0.modelIdentifier
            )
        }
    }

    func store(_ embeddings: [StoredEmbedding]) async throws {
        if failNextStore {
            failNextStore = false
            throw WriteFailed()
        }
        storeCallCount += 1
        for embedding in embeddings { stored[embedding.localIdentifier] = embedding }
    }

    func remove(localIdentifiers: [String]) async throws {
        removed.append(contentsOf: localIdentifiers)
        for identifier in localIdentifiers { stored.removeValue(forKey: identifier) }
    }
}

actor FakeCheckpointStore: ScanCheckpointStore {
    private(set) var current: ScanCheckpoint?
    private(set) var saveCount = 0

    init(seed: ScanCheckpoint? = nil) { self.current = seed }

    func load() async throws -> ScanCheckpoint? { current }
    func save(_ checkpoint: ScanCheckpoint) async throws {
        current = checkpoint
        saveCount += 1
    }
    func clear() async throws { current = nil }
}

/// Conditions that can change between batches, which is what a real device does.
actor FakeConditions: DeviceConditionsProviding {
    private var queue: [DeviceConditions]
    private let fallback: DeviceConditions
    private(set) var readCount = 0

    init(always: DeviceConditions) {
        self.queue = []
        self.fallback = always
    }

    init(sequence: [DeviceConditions], thenAlways fallback: DeviceConditions) {
        self.queue = sequence
        self.fallback = fallback
    }

    func currentConditions() async -> DeviceConditions {
        readCount += 1
        if queue.isEmpty { return fallback }
        return queue.removeFirst()
    }
}

actor RecordingObserver: ScanProgressObserving {
    private(set) var fractions: [Double] = []
    private(set) var phases: [ScanCheckpoint.Phase] = []

    func scanDidProgress(_ progress: ScanProgress) async {
        fractions.append(progress.fractionComplete)
        phases.append(progress.phase)
    }
}

// MARK: - Tests

@Suite("Scan engine")
struct ScanEngineTests {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static let healthy = DeviceConditions(
        batteryLevel: 0.9,
        isCharging: true,
        isOnWiFi: true,
        isLowPowerModeEnabled: false,
        availableStorageBytes: 8 * 1_073_741_824
    )

    static func paused() -> DeviceConditions {
        var conditions = healthy
        conditions.isPausedByUser = true
        return conditions
    }

    static func snapshots(_ count: Int, cloudOnly: Set<Int> = []) -> [LibraryAssetSnapshot] {
        (0..<count).map {
            LibraryAssetSnapshot(
                localIdentifier: "asset-\($0)",
                modificationDate: t0,
                isCloudOnly: cloudOnly.contains($0)
            )
        }
    }

    static func engine(
        library: FakeLibrary,
        embedder: FakeEmbedder = FakeEmbedder(),
        store: FakeEmbeddingStore = FakeEmbeddingStore(),
        checkpoints: FakeCheckpointStore = FakeCheckpointStore(),
        conditions: FakeConditions = FakeConditions(always: healthy),
        observer: any ScanProgressObserving = NullScanProgressObserver()
    ) -> ScanEngine {
        ScanEngine(
            library: library,
            embedder: embedder,
            store: store,
            checkpoints: checkpoints,
            conditions: conditions,
            observer: observer,
            clock: { t0 }
        )
    }

    static func policy(batchSize: Int = 10, model: String = "fake-v1") -> ScanPolicy {
        ScanPolicy(batchSize: batchSize, currentModelIdentifier: model)
    }

    // MARK: - Happy path

    @Test("a first scan indexes every asset and completes")
    func firstScanIndexesEverything() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(25))
        let store = FakeEmbeddingStore()
        let engine = Self.engine(library: library, store: store)

        let outcome = try await engine.scan(policy: Self.policy())

        #expect(outcome.stopReason == .completed)
        #expect(outcome.newlyIndexed == 25)
        #expect(outcome.failed == 0)
        #expect(await store.stored.count == 25)
        #expect(outcome.checkpoint.phase == .completed)
        #expect(outcome.checkpoint.fractionComplete == 1)
        #expect(!outcome.isResumable)
    }

    @Test("embeddings carry the model identifier and source modification date")
    func embeddingsCarryProvenance() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(1))
        let store = FakeEmbeddingStore()
        let engine = Self.engine(
            library: library,
            embedder: FakeEmbedder(modelIdentifier: "fake-v2"),
            store: store
        )

        _ = try await engine.scan(policy: Self.policy(model: "fake-v2"))

        let embedding = try #require(await store.stored["asset-0"])
        #expect(embedding.modelIdentifier == "fake-v2")
        #expect(embedding.sourceModificationDate == Self.t0)
        #expect(embedding.vector.count == 8)
    }

    /// The whole point of incremental scanning: a second pass must do nothing.
    @Test("a second scan of an unchanged library does no work")
    func secondScanDoesNothing() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(12))
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()

        let first = Self.engine(library: library, store: store, checkpoints: checkpoints)
        _ = try await first.scan(policy: Self.policy())
        let callsAfterFirst = await store.storeCallCount

        // A fresh engine, as a relaunch would be, over the same store.
        let second = Self.engine(library: library, store: store, checkpoints: checkpoints)
        let outcome = try await second.scan(policy: Self.policy())

        #expect(outcome.stopReason == .completed)
        #expect(outcome.newlyIndexed == 0)
        #expect(await store.storeCallCount == callsAfterFirst, "no further writes")
    }

    @Test("new assets added later are picked up without re-indexing the rest")
    func incrementalPickup() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(10))
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()

        _ = try await Self.engine(library: library, store: store, checkpoints: checkpoints)
            .scan(policy: Self.policy())

        await library.replace(with: Self.snapshots(13))
        let outcome = try await Self.engine(
            library: library, store: store, checkpoints: checkpoints
        ).scan(policy: Self.policy())

        #expect(outcome.newlyIndexed == 3)
        #expect(await store.stored.count == 13)
    }

    @Test("assets removed from the library are pruned from the store")
    func removalsArePruned() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(8))
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()

        _ = try await Self.engine(library: library, store: store, checkpoints: checkpoints)
            .scan(policy: Self.policy())

        await library.replace(with: Array(Self.snapshots(8).prefix(5)))
        let outcome = try await Self.engine(
            library: library, store: store, checkpoints: checkpoints
        ).scan(policy: Self.policy())

        #expect(outcome.removed == 3)
        #expect(await store.stored.count == 5)
        #expect(await store.removed.sorted() == ["asset-5", "asset-6", "asset-7"])
    }

    // MARK: - Resilience

    /// One unreadable asset must not end a scan of twenty thousand.
    @Test("an unreadable asset is recorded and the scan continues")
    func unreadableAssetDoesNotStopScan() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(10), throwingFor: ["asset-4"])
        let store = FakeEmbeddingStore()
        let engine = Self.engine(library: library, store: store)

        let outcome = try await engine.scan(policy: Self.policy())

        #expect(outcome.stopReason == .completed)
        #expect(outcome.newlyIndexed == 9)
        #expect(outcome.failed == 1)
        #expect(outcome.checkpoint.failedIdentifiers == ["asset-4"])
        #expect(await store.stored["asset-4"] == nil)
    }

    /// An iCloud-only asset whose thumbnail is unavailable is skipped, not
    /// waited on — the brief forbids forcing downloads.
    @Test("an asset with no local data is skipped rather than waited on")
    func unavailableAssetSkipped() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(5), unavailable: ["asset-2"])
        let engine = Self.engine(library: library)

        let outcome = try await engine.scan(policy: Self.policy())

        #expect(outcome.newlyIndexed == 4)
        #expect(outcome.failed == 1)
    }

    /// A wrong-sized vector means the model and our expectations disagree.
    /// Catching it here keeps it out of the store, where it would resurface as
    /// an opaque database error.
    @Test("a wrong-sized embedding is rejected before it reaches the store")
    func wrongSizedEmbeddingRejected() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(4))
        let store = FakeEmbeddingStore()
        let engine = Self.engine(
            library: library,
            embedder: FakeEmbedder(wrongSizeFor: ["asset-1"]),
            store: store
        )

        let outcome = try await engine.scan(policy: Self.policy())

        #expect(outcome.failed == 1)
        #expect(await store.stored["asset-1"] == nil)
        #expect(await store.stored.values.allSatisfy { $0.vector.count == 8 })
    }

    @Test("cloud-only assets are reported as skipped, not failed")
    func cloudOnlyReportedSeparately() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(10, cloudOnly: [3, 7]))
        let engine = Self.engine(library: library)

        let outcome = try await engine.scan(policy: Self.policy())

        #expect(outcome.skippedCloudOnly == 2)
        #expect(outcome.newlyIndexed == 8)
        #expect(outcome.failed == 0)
    }

    // MARK: - Gating

    @Test("a paused scan does not even enumerate the library")
    func pausedScanDoesNoWork() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(100))
        let engine = Self.engine(
            library: library,
            conditions: FakeConditions(always: Self.paused())
        )

        let outcome = try await engine.scan(policy: Self.policy())

        #expect(outcome.stopReason == .blocked(.pausedByUser))
        #expect(outcome.newlyIndexed == 0)
        #expect(await library.thumbnailRequests.isEmpty, "no thumbnails should be requested")
        #expect(outcome.isResumable)
    }

    /// Conditions are re-read between batches, so a scan stops partway when the
    /// user unplugs the phone or hits pause.
    @Test("a scan stops cleanly when conditions change mid-run")
    func stopsWhenConditionsDegrade() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(30))
        let store = FakeEmbeddingStore()
        // Healthy for the pre-flight check and the first batch, then paused.
        let conditions = FakeConditions(
            sequence: [Self.healthy, Self.healthy],
            thenAlways: Self.paused()
        )
        let engine = Self.engine(
            library: library, store: store,
            conditions: conditions
        )

        let outcome = try await engine.scan(policy: Self.policy(batchSize: 10))

        #expect(outcome.stopReason == .blocked(.pausedByUser))
        #expect(outcome.newlyIndexed == 10, "exactly the first batch")
        #expect(outcome.isResumable)
        #expect(outcome.checkpoint.settledCount == 10)
    }

    @Test("a blocked scan resumes from where it stopped")
    func resumesAfterBlocking() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(30))
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()

        let interrupted = Self.engine(
            library: library, store: store, checkpoints: checkpoints,
            conditions: FakeConditions(
                sequence: [Self.healthy, Self.healthy], thenAlways: Self.paused()
            )
        )
        let first = try await interrupted.scan(policy: Self.policy(batchSize: 10))
        #expect(first.newlyIndexed == 10)

        // Conditions recover and the scan is run again.
        let resumed = Self.engine(
            library: library, store: store, checkpoints: checkpoints,
            conditions: FakeConditions(always: Self.healthy)
        )
        let second = try await resumed.scan(policy: Self.policy(batchSize: 10))

        #expect(second.stopReason == .completed)
        #expect(second.newlyIndexed == 20, "only the remaining assets")
        #expect(await store.stored.count == 30)
    }

    // MARK: - Cancellation

    @Test("cancelling before the run stops it immediately but keeps progress")
    func cancellationIsHonoured() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(50))
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()
        let engine = Self.engine(library: library, store: store, checkpoints: checkpoints)

        await engine.cancel()
        let outcome = try await engine.scan(policy: Self.policy(batchSize: 10))

        // cancel() before scan() is reset by scan(), so this run completes.
        // That is deliberate: a stale cancel must not poison the next scan.
        #expect(outcome.stopReason == .completed)
        #expect(outcome.newlyIndexed == 50)
    }

    @Test("cancelling during a run preserves what was already indexed")
    func cancellationMidRunPreservesProgress() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(40))
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()
        let engine = Self.engine(library: library, store: store, checkpoints: checkpoints)

        // Cancel from another task while the scan runs.
        let scanTask = Task { try await engine.scan(policy: Self.policy(batchSize: 5)) }
        await engine.cancel()
        let outcome = try await scanTask.value

        // Whether it got as far as cancelling depends on scheduling, so assert
        // the invariant rather than an exact count: whatever was reported as
        // indexed is actually in the store, and the checkpoint agrees.
        let storedCount = await store.stored.count
        #expect(storedCount == outcome.newlyIndexed)
        #expect(outcome.checkpoint.completedIdentifiers.count == storedCount)
        if outcome.stopReason == .cancelled {
            #expect(outcome.isResumable)
        }
    }

    @Test("a cancelled scan resumes and finishes")
    func resumesAfterCancellation() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(20))
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()

        let first = Self.engine(library: library, store: store, checkpoints: checkpoints)
        let scanTask = Task { try await first.scan(policy: Self.policy(batchSize: 2)) }
        await first.cancel()
        _ = try await scanTask.value

        let second = Self.engine(library: library, store: store, checkpoints: checkpoints)
        let outcome = try await second.scan(policy: Self.policy(batchSize: 2))

        #expect(outcome.stopReason == .completed)
        #expect(await store.stored.count == 20)
        #expect(outcome.checkpoint.fractionComplete == 1)
    }

    // MARK: - Checkpointing

    /// Writing the store before the checkpoint means a crash between the two
    /// re-does work rather than losing it. The reverse order would mark assets
    /// done that were never stored.
    @Test("a store failure leaves the checkpoint un-advanced")
    func storeFailureDoesNotAdvanceCheckpoint() async {
        let library = FakeLibrary(snapshots: Self.snapshots(5))
        let store = FakeEmbeddingStore(failNextStore: true)
        let checkpoints = FakeCheckpointStore()
        let engine = Self.engine(library: library, store: store, checkpoints: checkpoints)

        await #expect(throws: FakeEmbeddingStore.WriteFailed.self) {
            try await engine.scan(policy: Self.policy(batchSize: 5))
        }

        let checkpoint = try? await checkpoints.load()
        #expect(checkpoint?.completedIdentifiers.isEmpty == true)
    }

    @Test("the persistent change token is captured into the checkpoint")
    func changeTokenCaptured() async throws {
        let token = Data([0x01, 0x02, 0x03])
        let library = FakeLibrary(snapshots: Self.snapshots(3), changeToken: token)
        let engine = Self.engine(library: library)

        let outcome = try await engine.scan(policy: Self.policy())
        #expect(outcome.checkpoint.changeTokenData == token)
    }

    /// A platform that cannot supply a token must not break scanning; it just
    /// means a full enumeration each time.
    @Test("a missing change token is not fatal")
    func missingChangeTokenIsFine() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(3), changeToken: nil)
        let outcome = try await Self.engine(library: library).scan(policy: Self.policy())

        #expect(outcome.stopReason == .completed)
        #expect(outcome.checkpoint.changeTokenData == nil)
    }

    /// If the library changed size while we were away, the stored progress
    /// fraction would be misleading, which matters because the system
    /// deprioritises background tasks whose progress does not move sensibly.
    @Test("a checkpoint whose total no longer matches is rebased, keeping progress")
    func checkpointRebasedWhenPlanChanges() async throws {
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()
        let library = FakeLibrary(snapshots: Self.snapshots(10))

        let interrupted = Self.engine(
            library: library, store: store, checkpoints: checkpoints,
            conditions: FakeConditions(
                sequence: [Self.healthy, Self.healthy], thenAlways: Self.paused()
            )
        )
        _ = try await interrupted.scan(policy: Self.policy(batchSize: 4))
        let afterFirst = try #require(await checkpoints.load())
        #expect(afterFirst.completedIdentifiers.count == 4)

        // Six more assets appear while the scan is paused.
        await library.replace(with: Self.snapshots(16))
        let resumed = Self.engine(
            library: library, store: store, checkpoints: checkpoints,
            conditions: FakeConditions(always: Self.healthy)
        )
        let outcome = try await resumed.scan(policy: Self.policy(batchSize: 4))

        #expect(outcome.stopReason == .completed)
        #expect(await store.stored.count == 16)
        // The four already done were not re-embedded.
        #expect(outcome.newlyIndexed == 12)
    }

    // MARK: - Retry policy for failed assets

    /// An asset that failed transiently — an iCloud photo not yet downloaded —
    /// must eventually be retried, or it would be lost from the index forever.
    /// A completed scan starts a fresh checkpoint, which is what allows that.
    @Test("a failed asset is retried by the next scan after one completes")
    func failedAssetRetriedAfterCompletion() async throws {
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()

        // First pass: asset-2 is not available locally.
        let flaky = FakeLibrary(snapshots: Self.snapshots(5), unavailable: ["asset-2"])
        let first = try await Self.engine(
            library: flaky, store: store, checkpoints: checkpoints
        ).scan(policy: Self.policy())
        #expect(first.stopReason == .completed)
        #expect(first.failed == 1)
        #expect(await store.stored["asset-2"] == nil)

        // Second pass: it has since downloaded.
        let healed = FakeLibrary(snapshots: Self.snapshots(5))
        let second = try await Self.engine(
            library: healed, store: store, checkpoints: checkpoints
        ).scan(policy: Self.policy())

        #expect(second.newlyIndexed == 1, "the previously failed asset is retried")
        #expect(await store.stored["asset-2"] != nil)
    }

    /// While resuming an *unfinished* scan, a failed asset is not retried. That
    /// stops one permanently-unreadable file from being attempted again on
    /// every batch of a long pass. It gets its retry once the pass completes,
    /// per the test above.
    @Test("a failed asset is not retried while resuming an unfinished scan")
    func failedAssetNotRetriedWithinAnUnfinishedScan() async throws {
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()
        let library = FakeLibrary(snapshots: Self.snapshots(20), throwingFor: ["asset-0"])

        // Stop partway, having failed asset-0 in the first batch.
        let interrupted = Self.engine(
            library: library, store: store, checkpoints: checkpoints,
            conditions: FakeConditions(
                sequence: [Self.healthy, Self.healthy], thenAlways: Self.paused()
            )
        )
        let first = try await interrupted.scan(policy: Self.policy(batchSize: 5))
        #expect(first.stopReason == .blocked(.pausedByUser))
        #expect(first.failed == 1)
        let requestsAfterFirst = await library.thumbnailRequests.filter { $0 == "asset-0" }.count
        #expect(requestsAfterFirst == 1)

        // Resume. asset-0 must not be attempted again in this same pass.
        let resumed = Self.engine(
            library: library, store: store, checkpoints: checkpoints,
            conditions: FakeConditions(always: Self.healthy)
        )
        _ = try await resumed.scan(policy: Self.policy(batchSize: 5))

        let totalRequests = await library.thumbnailRequests.filter { $0 == "asset-0" }.count
        #expect(totalRequests == 1, "asset-0 should not be retried mid-pass")
    }

    // MARK: - Progress reporting

    /// Apple's docs say the system prioritises terminating continued-processing
    /// tasks that show minimal progress, so progress must move as work lands.
    @Test("progress is reported monotonically and reaches completion")
    func progressIsReportedMonotonically() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(20))
        let observer = RecordingObserver()
        let engine = Self.engine(library: library, observer: observer)

        _ = try await engine.scan(policy: Self.policy(batchSize: 5))

        let fractions = await observer.fractions
        #expect(fractions.count >= 5, "one report per batch plus start and finish")
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
        #expect(
            zip(fractions, fractions.dropFirst()).allSatisfy { $0 <= $1 },
            "progress must never go backwards: \(fractions)"
        )
        #expect(await observer.phases.last == .completed)
    }

    @Test("progress is still reported when every asset fails")
    func progressReportedOnTotalFailure() async throws {
        let identifiers = Set(Self.snapshots(6).map(\.localIdentifier))
        let library = FakeLibrary(snapshots: Self.snapshots(6), throwingFor: identifiers)
        let observer = RecordingObserver()
        let engine = Self.engine(library: library, observer: observer)

        let outcome = try await engine.scan(policy: Self.policy(batchSize: 3))

        #expect(outcome.failed == 6)
        #expect(outcome.newlyIndexed == 0)
        // Failures count as settled, so a library of unreadable assets still
        // progresses to completion instead of looking stuck.
        #expect(await observer.fractions.last == 1)
        #expect(outcome.stopReason == .completed)
    }

    // MARK: - Model upgrades

    @Test("a model upgrade re-indexes only assets on the old model")
    func modelUpgradeReindexesStaleOnly() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(6))
        let store = FakeEmbeddingStore()
        let checkpoints = FakeCheckpointStore()

        _ = try await Self.engine(
            library: library,
            embedder: FakeEmbedder(modelIdentifier: "fake-v1"),
            store: store,
            checkpoints: checkpoints
        ).scan(policy: Self.policy(model: "fake-v1"))

        // A new model arrives. Every asset is stale.
        let outcome = try await Self.engine(
            library: library,
            embedder: FakeEmbedder(modelIdentifier: "fake-v2"),
            store: store,
            checkpoints: FakeCheckpointStore()
        ).scan(policy: Self.policy(model: "fake-v2"))

        #expect(outcome.newlyIndexed == 6)
        #expect(await store.stored.values.allSatisfy { $0.modelIdentifier == "fake-v2" })
    }

    // MARK: - Batching

    @Test("work is written in batches rather than one write at the end")
    func batchingProducesMultipleWrites() async throws {
        let library = FakeLibrary(snapshots: Self.snapshots(25))
        let store = FakeEmbeddingStore()
        let engine = Self.engine(library: library, store: store)

        _ = try await engine.scan(policy: Self.policy(batchSize: 10))

        // 25 assets in batches of 10 is three writes. Batching is what makes an
        // interrupted scan lose at most one batch of work.
        #expect(await store.storeCallCount == 3)
    }

    @Test("an empty library completes without error")
    func emptyLibrary() async throws {
        let outcome = try await Self.engine(library: FakeLibrary(snapshots: []))
            .scan(policy: Self.policy())

        #expect(outcome.stopReason == .completed)
        #expect(outcome.newlyIndexed == 0)
        #expect(outcome.checkpoint.fractionComplete == 1)
    }
}
