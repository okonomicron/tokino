import Foundation
import Testing
@testable import TokinoKit

/// The brief (§2.2) sets hard requirements on scanning: never rescan the whole
/// library, support incremental updates, detect deletions, avoid duplicate
/// indexing, and handle iCloud-only assets. Each gets a test here.
@Suite("Scan planner")
struct ScanPlannerTests {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let model = "mobileclip-s2-v1"

    static func policy(
        skipCloudOnly: Bool = true,
        model: String = ScanPlannerTests.model
    ) -> ScanPolicy {
        ScanPolicy(
            batchSize: 100,
            skipCloudOnlyAssets: skipCloudOnly,
            currentModelIdentifier: model
        )
    }

    static func asset(
        _ id: String,
        modified: Date? = nil,
        cloudOnly: Bool = false
    ) -> LibraryAssetSnapshot {
        LibraryAssetSnapshot(
            localIdentifier: id,
            modificationDate: modified,
            isCloudOnly: cloudOnly
        )
    }

    static func record(
        _ id: String,
        indexedAt: Date = ScanPlannerTests.t0,
        sourceModified: Date? = nil,
        model: String = ScanPlannerTests.model
    ) -> IndexedAssetRecord {
        IndexedAssetRecord(
            localIdentifier: id,
            indexedAt: indexedAt,
            sourceModificationDate: sourceModified,
            modelIdentifier: model
        )
    }

    // MARK: - First scan

    @Test("a first scan indexes everything and removes nothing")
    func firstScanIndexesAll() {
        let library = (1...5).map { Self.asset("a\($0)") }
        let plan = ScanPlanner.plan(library: library, indexed: [], policy: Self.policy())

        #expect(plan.toIndex.count == 5)
        #expect(plan.toReindex.isEmpty)
        #expect(plan.toRemove.isEmpty)
        #expect(plan.unchangedCount == 0)
        #expect(plan.totalWorkItems == 5)
        #expect(plan.hasWork)
    }

    // MARK: - The central requirement: do not rescan

    /// The requirement the brief states most forcefully: a second pass over an
    /// unchanged library must do no work at all.
    @Test("a second scan of an unchanged library does nothing")
    func unchangedLibraryIsNoWork() {
        let library = (1...1000).map { Self.asset("a\($0)", modified: Self.t0) }
        let indexed = (1...1000).map {
            Self.record("a\($0)", indexedAt: Self.t0, sourceModified: Self.t0)
        }

        let plan = ScanPlanner.plan(library: library, indexed: indexed, policy: Self.policy())

        #expect(plan.totalWorkItems == 0)
        #expect(plan.unchangedCount == 1000)
        #expect(plan.toRemove.isEmpty)
        #expect(!plan.hasWork)
    }

    @Test("only genuinely new assets are indexed on an incremental pass")
    func incrementalPassPicksUpOnlyNewAssets() {
        let library = (1...10).map { Self.asset("a\($0)", modified: Self.t0) }
        let indexed = (1...7).map { Self.record("a\($0)", sourceModified: Self.t0) }

        let plan = ScanPlanner.plan(library: library, indexed: indexed, policy: Self.policy())

        #expect(plan.toIndex.map(\.localIdentifier).sorted() == ["a10", "a8", "a9"])
        #expect(plan.unchangedCount == 7)
        #expect(plan.toReindex.isEmpty)
    }

    // MARK: - Modification detection

    @Test("an edited asset is re-indexed")
    func editedAssetIsReindexed() {
        let edited = Self.t0.addingTimeInterval(600)
        let plan = ScanPlanner.plan(
            library: [Self.asset("a1", modified: edited)],
            indexed: [Self.record("a1", sourceModified: Self.t0)],
            policy: Self.policy()
        )
        #expect(plan.toReindex.map(\.localIdentifier) == ["a1"])
        #expect(plan.toIndex.isEmpty)
        #expect(plan.unchangedCount == 0)
    }

    /// An asset whose modification date is older than what we stored is not
    /// re-indexed: time does not run backwards, so this is noise, not a change.
    @Test("an older modification date does not trigger re-indexing")
    func olderModificationDateIsIgnored() {
        let plan = ScanPlanner.plan(
            library: [Self.asset("a1", modified: Self.t0.addingTimeInterval(-600))],
            indexed: [Self.record("a1", sourceModified: Self.t0)],
            policy: Self.policy()
        )
        #expect(plan.toReindex.isEmpty)
        #expect(plan.unchangedCount == 1)
    }

    /// Without a modification date from the library we have no evidence of
    /// change. Re-indexing anyway would mean rescanning the library every pass.
    @Test("a missing modification date is treated as unchanged, not as work")
    func missingModificationDateIsNotWork() {
        let plan = ScanPlanner.plan(
            library: [Self.asset("a1", modified: nil)],
            indexed: [Self.record("a1", sourceModified: nil)],
            policy: Self.policy()
        )
        #expect(plan.totalWorkItems == 0)
        #expect(plan.unchangedCount == 1)
    }

    @Test("gaining a modification date where we had none counts as a change")
    func gainingModificationDateIsAChange() {
        let plan = ScanPlanner.plan(
            library: [Self.asset("a1", modified: Self.t0)],
            indexed: [Self.record("a1", sourceModified: nil)],
            policy: Self.policy()
        )
        #expect(plan.toReindex.map(\.localIdentifier) == ["a1"])
    }

    // MARK: - Model upgrades

    /// Vectors from different models are not comparable, so a model change must
    /// re-index — but only assets still on the old model.
    @Test("a model upgrade re-indexes only assets on the old model")
    func modelUpgradeReindexesStaleOnly() {
        let library = (1...4).map { Self.asset("a\($0)", modified: Self.t0) }
        let indexed = [
            Self.record("a1", sourceModified: Self.t0, model: "mobileclip-s2-v1"),
            Self.record("a2", sourceModified: Self.t0, model: "mobileclip-s2-v1"),
            Self.record("a3", sourceModified: Self.t0, model: "mobileclip-s2-v2"),
            Self.record("a4", sourceModified: Self.t0, model: "mobileclip-s2-v2")
        ]

        let plan = ScanPlanner.plan(
            library: library,
            indexed: indexed,
            policy: Self.policy(model: "mobileclip-s2-v2")
        )

        #expect(plan.toReindex.map(\.localIdentifier).sorted() == ["a1", "a2"])
        #expect(plan.unchangedCount == 2)
    }

    // MARK: - Deletions

    @Test("assets missing from the library are marked for removal")
    func deletionsAreDetected() {
        let library = [Self.asset("a1", modified: Self.t0)]
        let indexed = [
            Self.record("a1", sourceModified: Self.t0),
            Self.record("a2", sourceModified: Self.t0),
            Self.record("a3", sourceModified: Self.t0)
        ]

        let plan = ScanPlanner.plan(library: library, indexed: indexed, policy: Self.policy())

        #expect(plan.toRemove == ["a2", "a3"])
        #expect(plan.hasWork, "a plan with only removals still has work to do")
        #expect(plan.totalWorkItems == 0, "removals are not indexing work")
    }

    // MARK: - iCloud-only assets

    @Test("cloud-only assets are skipped rather than downloaded")
    func cloudOnlyAssetsSkipped() {
        let library = [
            Self.asset("local1"),
            Self.asset("cloud1", cloudOnly: true),
            Self.asset("cloud2", cloudOnly: true)
        ]
        let plan = ScanPlanner.plan(library: library, indexed: [], policy: Self.policy())

        #expect(plan.toIndex.map(\.localIdentifier) == ["local1"])
        #expect(plan.skippedCloudOnly.sorted() == ["cloud1", "cloud2"])
    }

    /// A skipped cloud asset must not be mistaken for a deletion, or every pass
    /// would delete and re-add it.
    @Test("a skipped cloud-only asset is not treated as deleted")
    func skippedCloudAssetIsNotADeletion() {
        let library = [Self.asset("cloud1", cloudOnly: true)]
        let indexed = [Self.record("cloud1", sourceModified: Self.t0)]

        let plan = ScanPlanner.plan(library: library, indexed: indexed, policy: Self.policy())

        #expect(plan.toRemove.isEmpty, "a cloud-only asset still exists; it is just not downloaded")
        #expect(plan.skippedCloudOnly == ["cloud1"])
    }

    @Test("cloud-only assets are indexed when the policy allows it")
    func cloudOnlyIndexedWhenPolicyAllows() {
        let library = [Self.asset("cloud1", cloudOnly: true)]
        let plan = ScanPlanner.plan(
            library: library,
            indexed: [],
            policy: Self.policy(skipCloudOnly: false)
        )
        #expect(plan.toIndex.map(\.localIdentifier) == ["cloud1"])
        #expect(plan.skippedCloudOnly.isEmpty)
    }

    // MARK: - Duplicate protection

    @Test("a duplicated library entry is indexed once")
    func duplicateLibraryEntriesCollapse() {
        let library = [Self.asset("a1"), Self.asset("a1"), Self.asset("a1")]
        let plan = ScanPlanner.plan(library: library, indexed: [], policy: Self.policy())
        #expect(plan.toIndex.count == 1)
    }

    /// Duplicate rows in our own store are an upstream bug; the planner keeps
    /// the newest rather than failing a user's scan over it.
    @Test("duplicate index records resolve to the most recent")
    func duplicateIndexRecordsResolveToNewest() {
        let later = Self.t0.addingTimeInterval(3600)
        let indexed = [
            Self.record("a1", indexedAt: Self.t0, sourceModified: Self.t0, model: "old-model"),
            Self.record("a1", indexedAt: later, sourceModified: Self.t0, model: Self.model)
        ]
        let plan = ScanPlanner.plan(
            library: [Self.asset("a1", modified: Self.t0)],
            indexed: indexed,
            policy: Self.policy()
        )
        // The newer record is on the current model, so there is nothing to do.
        #expect(plan.totalWorkItems == 0)
        #expect(plan.unchangedCount == 1)
    }

    // MARK: - Batching

    @Test("work is batched to the requested size with a short final batch")
    func batchingSplitsWork() {
        let library = (1...250).map { Self.asset("a\($0)") }
        let plan = ScanPlanner.plan(library: library, indexed: [], policy: Self.policy())

        let batches = plan.batches(size: 100)
        #expect(batches.count == 3)
        #expect(batches[0].count == 100)
        #expect(batches[2].count == 50)
        #expect(batches.flatMap { $0 }.count == 250)
    }

    @Test("batching an empty plan yields no batches")
    func batchingEmptyPlan() {
        let plan = ScanPlanner.plan(library: [], indexed: [], policy: Self.policy())
        #expect(plan.batches(size: 100).isEmpty)
    }

    @Test("new assets are ordered before re-indexes")
    func newAssetsComeFirst() {
        let library = [
            Self.asset("stale", modified: Self.t0.addingTimeInterval(600)),
            Self.asset("brand-new")
        ]
        let indexed = [Self.record("stale", sourceModified: Self.t0)]
        let plan = ScanPlanner.plan(library: library, indexed: indexed, policy: Self.policy())

        #expect(plan.orderedWorkItems.map(\.localIdentifier) == ["brand-new", "stale"])
    }
}
