import Foundation
import Observation
import TokinoKit

/// Assembles a `ScanEngine` from the real iOS implementations and exposes its
/// progress to the UI.
///
/// Deliberately thin. The scan's behaviour — planning, batching, checkpointing,
/// gating, resuming — is `ScanEngine` in TokinoKit, tested on Linux. This wires
/// PhotoKit, Core ML and SQLite into it, keeps the metadata the index needs in
/// step, and publishes progress.
@MainActor
@Observable
final class ScanCoordinator {

    enum Status: Equatable {
        case idle
        case scanning(ScanProgressSnapshot)
        case finished(indexed: Int, failed: Int, deferredToCloud: Int)
        /// Stopped by device conditions, with the reason so the UI can be
        /// specific — "waiting for Wi-Fi" rather than an indefinite spinner.
        case waiting(ScanGate.Reason)
        case failed(String)
    }

    /// A value-typed snapshot, so the view does not hold TokinoKit's progress
    /// type and SwiftUI can diff it cheaply.
    struct ScanProgressSnapshot: Equatable {
        let completed: Int
        let failed: Int
        let deferredToCloud: Int
        let total: Int
        let fraction: Double
        let estimatedTimeRemaining: TimeInterval?
    }

    private(set) var status: Status = .idle

    private let library: PhotoKitLibrary
    private let embedder: CoreMLEmbedder
    private let store: LocalVectorStore
    private let conditions: DeviceConditionsMonitor
    private var policy: ScanPolicy

    private var engine: ScanEngine?
    private var scanTask: Task<Void, Never>?

    init(
        library: PhotoKitLibrary,
        embedder: CoreMLEmbedder,
        store: LocalVectorStore,
        conditions: DeviceConditionsMonitor,
        policy: ScanPolicy
    ) {
        self.library = library
        self.embedder = embedder
        self.store = store
        self.conditions = conditions
        self.policy = policy
    }

    var isScanning: Bool {
        if case .scanning = status { return true }
        return false
    }

    /// Starts or resumes a scan.
    ///
    /// Must be called from a user action. `BGContinuedProcessingTask`, which
    /// M2b uses to let this continue in the background, requires submission
    /// from the foreground in response to something the person did — so a
    /// user-initiated entry point is the right shape even before that lands.
    func startScan() {
        guard !isScanning else { return }

        let engine = ScanEngine(
            library: library,
            embedder: embedder,
            store: store,
            checkpoints: CheckpointStoreAdapter(store: store),
            conditions: conditions,
            observer: ProgressBridge { [weak self] snapshot in
                Task { @MainActor in self?.status = .scanning(snapshot) }
            }
        )
        self.engine = engine

        scanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await engine.scan(policy: policy)

                // Metadata is gathered after indexing rather than during,
                // because PhotoKit's album inversion is one pass over every
                // album and doing it per batch would repeat that work.
                await attachMetadata(for: outcome)

                switch outcome.stopReason {
                case .completed:
                    status = .finished(
                        indexed: outcome.newlyIndexed,
                        failed: outcome.failed,
                        deferredToCloud: outcome.deferredToCloud
                    )
                case .blocked(let reason):
                    status = .waiting(reason)
                case .cancelled:
                    status = .idle
                }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        let engine = self.engine
        Task { await engine?.cancel() }
    }

    /// Fills in the coordinates, albums and dimensions search filters read.
    ///
    /// Failures here are logged rather than surfaced: the embeddings are the
    /// valuable part and are already stored, so missing metadata degrades
    /// filtering rather than losing the scan.
    private func attachMetadata(for outcome: ScanOutcome) async {
        let identifiers = Array(outcome.checkpoint.completedIdentifiers)
        guard !identifiers.isEmpty else { return }

        let metadata = library.metadata(for: identifiers)
        do {
            try await store.storeMetadata(metadata)
        } catch {
            // Deliberately swallowed. Losing metadata costs filtering accuracy;
            // failing the scan here would cost the user the whole index.
        }
    }

    /// Updates the scan policy, for the settings screen.
    func updatePolicy(_ policy: ScanPolicy) {
        self.policy = policy
    }
}

/// Bridges `ScanEngine`'s observer protocol to the main actor.
private struct ProgressBridge: ScanProgressObserving {
    let onProgress: @Sendable (ScanCoordinator.ScanProgressSnapshot) -> Void

    func scanDidProgress(_ progress: ScanProgress) async {
        onProgress(
            ScanCoordinator.ScanProgressSnapshot(
                completed: progress.completed,
                failed: progress.failed,
                deferredToCloud: progress.deferredToCloud,
                total: progress.total,
                fraction: progress.fractionComplete,
                estimatedTimeRemaining: progress.estimatedTimeRemaining
            )
        )
    }
}

/// Adapts `LocalVectorStore`'s blob storage to `ScanCheckpointStore`.
///
/// The checkpoint lives in the same SQLite file as the index, so the two cannot
/// disagree about what has been indexed — two files could be backed up or
/// restored independently and drift.
private struct CheckpointStoreAdapter: ScanCheckpointStore {
    let store: LocalVectorStore

    func load() async throws -> ScanCheckpoint? {
        guard let data = try await store.loadCheckpointData() else { return nil }
        // A checkpoint written by an older build may not decode. Starting fresh
        // costs a rescan; refusing to launch would be worse.
        return try? JSONDecoder().decode(ScanCheckpoint.self, from: data)
    }

    func save(_ checkpoint: ScanCheckpoint) async throws {
        try await store.saveCheckpointData(JSONEncoder().encode(checkpoint))
    }

    func clear() async throws {
        try await store.clearCheckpoint()
    }
}
