import Foundation

/// Durable progress for a scan, so an interrupted run resumes instead of
/// starting over (§2.2: persist checkpoints, recover safely from interruption).
///
/// Codable and value-typed: the iOS layer writes it after each batch, and a
/// relaunch reads it back with no reconstruction logic.
public struct ScanCheckpoint: Sendable, Hashable, Codable {
    public enum Phase: String, Sendable, Codable {
        /// Walking the library to build the plan.
        case enumerating
        /// Embedding batches.
        case indexing
        /// Removing records for assets no longer visible.
        case pruning
        case completed
        case cancelled
    }

    public let sessionID: Identifier<ScanCheckpoint>
    public var phase: Phase
    /// Total work items the plan found. Fixed once indexing begins.
    public let totalWorkItems: Int
    /// Identifiers successfully indexed. Held as a set so a replayed batch
    /// cannot inflate progress or double-count.
    public var completedIdentifiers: Set<String>
    /// Identifiers that failed and should not be retried indefinitely.
    public var failedIdentifiers: Set<String>
    public let startedAt: Date
    public var updatedAt: Date
    /// PhotoKit's persistent change token at the moment the plan was built,
    /// opaque to us. Lets the next run ask the library only what changed since,
    /// rather than re-enumerating everything.
    public var changeTokenData: Data?

    public init(
        sessionID: Identifier<ScanCheckpoint> = Identifier(),
        phase: Phase = .enumerating,
        totalWorkItems: Int,
        completedIdentifiers: Set<String> = [],
        failedIdentifiers: Set<String> = [],
        startedAt: Date,
        updatedAt: Date,
        changeTokenData: Data? = nil
    ) {
        self.sessionID = sessionID
        self.phase = phase
        self.totalWorkItems = totalWorkItems
        self.completedIdentifiers = completedIdentifiers
        self.failedIdentifiers = failedIdentifiers
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.changeTokenData = changeTokenData
    }

    /// Items settled one way or the other.
    public var settledCount: Int { completedIdentifiers.count + failedIdentifiers.count }

    public var remainingCount: Int { max(0, totalWorkItems - settledCount) }

    /// 0...1. Reported to `BGContinuedProcessingTask`, which the system uses to
    /// decide what to terminate first: Apple's documentation states it
    /// prioritises killing tasks that show minimal or no progress. So this must
    /// move as real work completes, not on a timer.
    public var fractionComplete: Double {
        guard totalWorkItems > 0 else { return phase == .completed ? 1 : 0 }
        return (Double(settledCount) / Double(totalWorkItems)).clamped(to: 0...1)
    }

    public var isFinished: Bool { phase == .completed || phase == .cancelled }

    /// Records a batch outcome and advances the phase when the work is done.
    ///
    /// Mutating rather than returning a new value because callers persist this
    /// after every batch, and a copy-then-save pattern invites losing a write.
    public mutating func recordBatch(
        succeeded: [String],
        failed: [String] = [],
        at date: Date
    ) {
        completedIdentifiers.formUnion(succeeded)
        // An identifier that later succeeds should not stay marked failed.
        failedIdentifiers.subtract(succeeded)
        failedIdentifiers.formUnion(failed.filter { !completedIdentifiers.contains($0) })
        updatedAt = date
        if phase == .indexing && remainingCount == 0 {
            phase = .pruning
        }
    }

    /// Items from a plan that still need work, given what this checkpoint
    /// records. This is what makes resume correct: the caller re-derives the
    /// remaining queue rather than trusting a stored index that may not line up
    /// with a freshly-built plan.
    public func pendingItems(from plan: ScanPlan) -> [LibraryAssetSnapshot] {
        plan.orderedWorkItems.filter {
            !completedIdentifiers.contains($0.localIdentifier)
                && !failedIdentifiers.contains($0.localIdentifier)
        }
    }
}

/// A snapshot for the UI and for Live Activity updates.
public struct ScanProgress: Sendable, Hashable {
    public let phase: ScanCheckpoint.Phase
    public let completed: Int
    public let failed: Int
    public let total: Int
    public let fractionComplete: Double
    /// Nil until enough work has completed to estimate meaningfully. Showing a
    /// wild estimate from a handful of samples is worse than showing none.
    public let estimatedTimeRemaining: TimeInterval?

    public init(checkpoint: ScanCheckpoint, now: Date) {
        self.phase = checkpoint.phase
        self.completed = checkpoint.completedIdentifiers.count
        self.failed = checkpoint.failedIdentifiers.count
        self.total = checkpoint.totalWorkItems
        self.fractionComplete = checkpoint.fractionComplete

        let settled = checkpoint.settledCount
        let elapsed = now.timeIntervalSince(checkpoint.startedAt)
        // 25 items is enough to smooth out the first few slow loads without
        // making the estimate appear only near the end.
        if settled >= 25, elapsed > 0, checkpoint.remainingCount > 0 {
            let perItem = elapsed / Double(settled)
            self.estimatedTimeRemaining = perItem * Double(checkpoint.remainingCount)
        } else {
            self.estimatedTimeRemaining = nil
        }
    }
}
