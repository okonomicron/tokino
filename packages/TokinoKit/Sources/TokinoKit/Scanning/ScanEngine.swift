import Foundation

/// How a scan ended.
public struct ScanOutcome: Sendable, Hashable {
    public enum StopReason: Sendable, Hashable {
        /// All planned work finished.
        case completed
        /// The caller cancelled, or the task was cancelled by the system.
        case cancelled
        /// Device conditions no longer permit scanning. Carries the reason so
        /// the UI can say "waiting for Wi-Fi" rather than stalling silently.
        case blocked(ScanGate.Reason)
    }

    public let checkpoint: ScanCheckpoint
    public let newlyIndexed: Int
    public let failed: Int
    public let removed: Int
    /// Photos whose data is only in iCloud, discovered during the scan. Not
    /// failures: a later scan picks them up once they have downloaded.
    public let deferredToCloud: Int
    public let stopReason: StopReason

    /// True when the scan can be resumed by calling the engine again.
    public var isResumable: Bool {
        switch stopReason {
        case .completed: return false
        case .cancelled, .blocked: return true
        }
    }
}

/// Drives a photo library scan: plan, embed in batches, checkpoint, prune.
///
/// This is the orchestration the pure types from Milestone 1 were built for. It
/// owns no algorithms of its own — `ScanPlanner` decides what needs doing,
/// `ScanGate` decides whether now is a good time, and `ScanCheckpoint` records
/// what is done. The engine's whole job is sequencing those correctly and
/// surviving interruption, which is why it depends only on protocols and can be
/// tested on Linux with fakes.
///
/// An actor because a scan is long-running and the app may ask about progress or
/// cancel while it runs.
public actor ScanEngine {

    private let library: any PhotoLibraryReading
    private let embedder: any ImageEmbedding
    private let store: any EmbeddingStore
    private let checkpoints: any ScanCheckpointStore
    private let conditions: any DeviceConditionsProviding
    private let observer: any ScanProgressObserving
    private let clock: @Sendable () -> Date

    /// Set by `cancel()`. Checked between assets, so cancellation takes effect
    /// within one embedding rather than at the end of a batch.
    private var isCancelled = false

    public init(
        library: any PhotoLibraryReading,
        embedder: any ImageEmbedding,
        store: any EmbeddingStore,
        checkpoints: any ScanCheckpointStore,
        conditions: any DeviceConditionsProviding,
        observer: any ScanProgressObserving = NullScanProgressObserver(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.library = library
        self.embedder = embedder
        self.store = store
        self.checkpoints = checkpoints
        self.conditions = conditions
        self.observer = observer
        self.clock = clock
    }

    /// Asks the running scan to stop at the next asset boundary.
    ///
    /// Progress already made is kept: the checkpoint is saved before returning,
    /// so resuming re-queues only unfinished work.
    public func cancel() {
        isCancelled = true
    }

    /// Runs or resumes a scan.
    ///
    /// Returns rather than throwing for the ordinary stop reasons — cancelled
    /// and blocked are normal outcomes, not errors. It throws only when the
    /// library or store genuinely fails.
    public func scan(policy: ScanPolicy = ScanPolicy()) async throws -> ScanOutcome {
        isCancelled = false

        // Conditions are checked before any work: there is no point enumerating
        // a 20,000-asset library when the user has scanning paused.
        let initial = await conditions.currentConditions()
        if case .blocked(let reason) = ScanGate.evaluate(conditions: initial, policy: policy) {
            let existing = try await checkpoints.load()
            return ScanOutcome(
                checkpoint: existing ?? ScanCheckpoint(
                    totalWorkItems: 0, startedAt: clock(), updatedAt: clock()
                ),
                newlyIndexed: 0, failed: 0, removed: 0, deferredToCloud: 0,
                stopReason: .blocked(reason)
            )
        }

        // Always re-plan rather than trusting a stored queue. The library may
        // have changed while we were away, and ScanCheckpoint filters by
        // identifier, so a freshly-built plan resumes correctly.
        let snapshots = try await library.enumerateAssets()
        let indexed = try await store.indexedRecords()
        let plan = ScanPlanner.plan(library: snapshots, indexed: indexed, policy: policy)

        var checkpoint = try await resumableCheckpoint(for: plan)
        checkpoint.phase = .indexing
        checkpoint.changeTokenData = await library.currentChangeToken()
        try await checkpoints.save(checkpoint)
        await report(checkpoint)

        let pending = checkpoint.pendingItems(from: plan)
        let modificationDates = Dictionary(
            snapshots.map { ($0.localIdentifier, $0.modificationDate) },
            uniquingKeysWith: { first, _ in first }
        )

        var newlyIndexed = 0
        var failedCount = 0
        var deferredCount = 0

        for batch in pending.chunked(into: policy.batchSize) {
            // Re-read conditions between batches: a phone gets unplugged, Wi-Fi
            // drops, the user hits pause.
            let current = await conditions.currentConditions()
            if case .blocked(let reason) = ScanGate.evaluate(conditions: current, policy: policy) {
                try await checkpoints.save(checkpoint)
                return ScanOutcome(
                    checkpoint: checkpoint, newlyIndexed: newlyIndexed, failed: failedCount,
                    removed: 0, deferredToCloud: deferredCount,
                    stopReason: .blocked(reason)
                )
            }

            if isCancelled || Task.isCancelled {
                try await checkpoints.save(checkpoint)
                return ScanOutcome(
                    checkpoint: checkpoint, newlyIndexed: newlyIndexed, failed: failedCount,
                    removed: 0, deferredToCloud: deferredCount,
                    stopReason: .cancelled
                )
            }

            var embeddings: [StoredEmbedding] = []
            var succeeded: [String] = []
            var failed: [String] = []
            var deferred: [String] = []

            for snapshot in batch {
                // Checked per asset so cancelling a scan feels immediate rather
                // than waiting out a 200-asset batch.
                if isCancelled || Task.isCancelled { break }

                do {
                    let outcome = try await library.thumbnail(
                        for: snapshot.localIdentifier,
                        maxPixelSize: embedder.preferredInputPixelSize
                    )

                    let imageData: Data
                    switch outcome {
                    case .available(let data):
                        imageData = data
                    case .deferredToCloud:
                        // Only in iCloud. Recorded separately from a failure so
                        // the user is told their photos are waiting, not broken.
                        deferred.append(snapshot.localIdentifier)
                        continue
                    case .unavailable:
                        failed.append(snapshot.localIdentifier)
                        continue
                    }

                    let vector = try await embedder.embed(imageData: imageData)
                    guard vector.count == embedder.dimensions else {
                        // A wrong-sized vector means the model and our
                        // expectations disagree. Rejecting it here keeps it out
                        // of the store, where it would surface much later as an
                        // opaque failure.
                        failed.append(snapshot.localIdentifier)
                        continue
                    }

                    embeddings.append(
                        StoredEmbedding(
                            localIdentifier: snapshot.localIdentifier,
                            vector: vector,
                            modelIdentifier: embedder.modelIdentifier,
                            sourceModificationDate: modificationDates[snapshot.localIdentifier]
                                ?? snapshot.modificationDate,
                            embeddedAt: clock()
                        )
                    )
                    succeeded.append(snapshot.localIdentifier)
                } catch {
                    // One unreadable or undecodable asset must not end a scan of
                    // twenty thousand. It is recorded and skipped.
                    failed.append(snapshot.localIdentifier)
                }
            }

            if !embeddings.isEmpty {
                // Persisted before the checkpoint records them, so a crash
                // between the two re-does work rather than losing it. The
                // reverse order would mark assets done that were never stored.
                try await store.store(embeddings)
            }

            newlyIndexed += succeeded.count
            failedCount += failed.count
            deferredCount += deferred.count
            checkpoint.recordBatch(
                succeeded: succeeded, failed: failed, deferred: deferred, at: clock()
            )
            try await checkpoints.save(checkpoint)
            await report(checkpoint)

            if isCancelled || Task.isCancelled {
                return ScanOutcome(
                    checkpoint: checkpoint, newlyIndexed: newlyIndexed, failed: failedCount,
                    removed: 0, deferredToCloud: deferredCount,
                    stopReason: .cancelled
                )
            }
        }

        // Pruning last: removing records for assets that are gone is cheap and
        // safe, but doing it before indexing would waste the work if the scan
        // were then interrupted.
        checkpoint.phase = .pruning
        try await checkpoints.save(checkpoint)
        if !plan.toRemove.isEmpty {
            try await store.remove(localIdentifiers: plan.toRemove)
        }

        checkpoint.phase = .completed
        checkpoint.updatedAt = clock()
        try await checkpoints.save(checkpoint)
        await report(checkpoint)

        return ScanOutcome(
            checkpoint: checkpoint,
            newlyIndexed: newlyIndexed,
            failed: failedCount,
            removed: plan.toRemove.count,
            deferredToCloud: deferredCount,
            stopReason: .completed
        )
    }

    /// Loads an existing checkpoint when it still applies, or starts a new one.
    ///
    /// A stored checkpoint is reused only while it is unfinished and its total
    /// matches the plan we just built. If the library changed enough to change
    /// the amount of work, the old progress fraction would be misleading, and
    /// `BGContinuedProcessingTask` is sensitive to progress that does not move
    /// sensibly — so a fresh checkpoint is started, carrying forward what was
    /// already completed.
    private func resumableCheckpoint(for plan: ScanPlan) async throws -> ScanCheckpoint {
        let stored = try? await checkpoints.load()

        guard let stored, !stored.isFinished else {
            return ScanCheckpoint(
                totalWorkItems: plan.totalWorkItems,
                startedAt: clock(),
                updatedAt: clock()
            )
        }

        if stored.totalWorkItems == plan.totalWorkItems {
            return stored
        }

        // The plan changed size. Keep what is genuinely done, reset the total.
        return ScanCheckpoint(
            sessionID: stored.sessionID,
            phase: .indexing,
            totalWorkItems: plan.totalWorkItems,
            completedIdentifiers: stored.completedIdentifiers,
            failedIdentifiers: stored.failedIdentifiers,
            deferredIdentifiers: stored.deferredIdentifiers,
            startedAt: stored.startedAt,
            updatedAt: clock(),
            changeTokenData: stored.changeTokenData
        )
    }

    private func report(_ checkpoint: ScanCheckpoint) async {
        await observer.scanDidProgress(ScanProgress(checkpoint: checkpoint, now: clock()))
    }
}

extension Array {
    /// Splits into consecutive chunks of at most `size`.
    ///
    /// `ScanPlan.batches(size:)` does this for a plan; this handles the
    /// already-filtered pending list, which is what resuming works from.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
