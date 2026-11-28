import Foundation
import Testing
@testable import TokinoKit

@Suite("Index sync planner")
struct IndexSyncPlannerTests {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let model = "openclip-vit-b32-laion2b-v1"

    static func local(
        _ id: String,
        indexedAt: Date = t0,
        model: String = IndexSyncPlannerTests.model
    ) -> IndexedAssetRecord {
        IndexedAssetRecord(
            localIdentifier: id,
            indexedAt: indexedAt,
            sourceModificationDate: t0,
            modelIdentifier: model
        )
    }

    static func remote(
        _ id: String,
        syncedAt: Date = t0,
        model: String = IndexSyncPlannerTests.model
    ) -> RemoteIndexRecord {
        RemoteIndexRecord(localIdentifier: id, modelIdentifier: model, syncedAt: syncedAt)
    }

    // MARK: - First sync

    @Test("a first sync uploads everything")
    func firstSyncUploadsAll() {
        let plan = IndexSyncPlanner.plan(
            local: (1...5).map { Self.local("a\($0)") },
            remote: []
        )
        #expect(plan.toUpload.count == 5)
        #expect(plan.toDeleteRemotely.isEmpty)
        #expect(plan.alreadyInSync == 0)
        #expect(plan.hasWork)
    }

    /// The point of syncing incrementally: a second pass must be free.
    @Test("an already-synced index needs no work")
    func noWorkWhenInSync() {
        let plan = IndexSyncPlanner.plan(
            local: (1...100).map { Self.local("a\($0)") },
            remote: (1...100).map { Self.remote("a\($0)") }
        )
        #expect(!plan.hasWork)
        #expect(plan.alreadyInSync == 100)
        #expect(plan.totalOperations == 0)
    }

    @Test("only new assets are uploaded on an incremental pass")
    func incrementalUploadsOnlyNew() {
        let plan = IndexSyncPlanner.plan(
            local: (1...10).map { Self.local("a\($0)") },
            remote: (1...6).map { Self.remote("a\($0)") }
        )
        #expect(plan.toUpload.sorted() == ["a10", "a7", "a8", "a9"])
        #expect(plan.alreadyInSync == 6)
    }

    // MARK: - Staleness

    @Test("an asset re-embedded since the last sync is uploaded again")
    func reembeddedAssetIsUploaded() {
        let plan = IndexSyncPlanner.plan(
            local: [Self.local("a1", indexedAt: Self.t0.addingTimeInterval(60))],
            remote: [Self.remote("a1", syncedAt: Self.t0)]
        )
        #expect(plan.toUpload == ["a1"])
    }

    /// Equal timestamps must not upload, or a clock that has not moved would
    /// cause an endless sync loop.
    @Test("an identical timestamp does not trigger an upload")
    func equalTimestampIsInSync() {
        let plan = IndexSyncPlanner.plan(
            local: [Self.local("a1", indexedAt: Self.t0)],
            remote: [Self.remote("a1", syncedAt: Self.t0)]
        )
        #expect(plan.toUpload.isEmpty)
        #expect(plan.alreadyInSync == 1)
    }

    /// A remote timestamp ahead of the local one means the server has something
    /// newer, which should not cause a pointless re-upload.
    @Test("a remote record newer than the local one is left alone")
    func newerRemoteIsLeftAlone() {
        let plan = IndexSyncPlanner.plan(
            local: [Self.local("a1", indexedAt: Self.t0)],
            remote: [Self.remote("a1", syncedAt: Self.t0.addingTimeInterval(600))]
        )
        #expect(plan.toUpload.isEmpty)
    }

    /// A different model means the stored vector is not comparable with what
    /// the device now produces, so timestamps are irrelevant.
    @Test("a model change forces re-upload regardless of timestamps")
    func modelChangeForcesUpload() {
        let plan = IndexSyncPlanner.plan(
            local: [Self.local("a1", indexedAt: Self.t0, model: "model-v2")],
            // Remote is newer, but on the old model.
            remote: [
                Self.remote("a1", syncedAt: Self.t0.addingTimeInterval(9999), model: "model-v1")
            ]
        )
        #expect(plan.toUpload == ["a1"])
    }

    // MARK: - Deletions

    @Test("rows for assets no longer on the device are deleted remotely")
    func deletionsPropagate() {
        let plan = IndexSyncPlanner.plan(
            local: [Self.local("a1")],
            remote: [Self.remote("a1"), Self.remote("a2"), Self.remote("a3")]
        )
        #expect(plan.toDeleteRemotely == ["a2", "a3"])
        #expect(plan.hasWork)
        #expect(plan.toUpload.isEmpty)
    }

    @Test("a plan of only deletions still counts as work")
    func deletionOnlyPlanHasWork() {
        let plan = IndexSyncPlanner.plan(local: [], remote: [Self.remote("gone")])
        #expect(plan.hasWork)
        #expect(plan.totalOperations == 1)
    }

    // MARK: - Duplicate protection

    @Test("a duplicated local record is uploaded once")
    func duplicateLocalCollapses() {
        let plan = IndexSyncPlanner.plan(
            local: [Self.local("a1"), Self.local("a1"), Self.local("a1")],
            remote: []
        )
        #expect(plan.toUpload == ["a1"])
    }

    /// A duplicate from the server is a bug there; comparing against the newest
    /// is more useful than failing the sync.
    @Test("duplicate remote records resolve to the most recent")
    func duplicateRemoteResolvesToNewest() {
        let plan = IndexSyncPlanner.plan(
            local: [Self.local("a1", indexedAt: Self.t0)],
            remote: [
                Self.remote("a1", syncedAt: Self.t0.addingTimeInterval(-600)),
                Self.remote("a1", syncedAt: Self.t0),
            ]
        )
        #expect(plan.toUpload.isEmpty, "the newer remote record is already in sync")
    }

    @Test("a duplicated remote record is deleted once, not twice")
    func duplicateRemoteDeletedOnce() {
        let plan = IndexSyncPlanner.plan(
            local: [],
            remote: [Self.remote("gone"), Self.remote("gone")]
        )
        #expect(plan.toDeleteRemotely == ["gone"])
    }

    // MARK: - Batching

    /// A single enormous request risks a gateway timeout and loses everything
    /// on retry; batching bounds what a failure costs.
    @Test("uploads batch to the requested size")
    func uploadBatching() {
        let plan = IndexSyncPlanner.plan(
            local: (1...250).map { Self.local("a\($0)") },
            remote: []
        )
        let batches = plan.uploadBatches(size: 100)
        #expect(batches.count == 3)
        #expect(batches[0].count == 100)
        #expect(batches[2].count == 50)
        #expect(batches.flatMap { $0 }.count == 250)
    }

    @Test("batching an empty plan yields no batches")
    func batchingEmptyPlan() {
        let plan = IndexSyncPlanner.plan(local: [], remote: [])
        #expect(plan.uploadBatches(size: 100).isEmpty)
        #expect(!plan.hasWork)
    }

    // MARK: - Row validation

    @Test("a well-formed row passes validation")
    func validRowPasses() {
        let row = IndexSyncRow(
            localIdentifier: "a1",
            vector: [Float](repeating: 0.1, count: 512),
            modelIdentifier: Self.model,
            indexedAt: Self.t0
        )
        #expect(row.hasValidVector(expectedDimensions: 512))
    }

    /// Caught here rather than as an opaque Postgres complaint about vector
    /// dimensions, a long way from the cause.
    @Test("a wrong-sized vector fails validation")
    func wrongSizeFailsValidation() {
        let row = IndexSyncRow(
            localIdentifier: "a1",
            vector: [Float](repeating: 0.1, count: 256),
            modelIdentifier: Self.model,
            indexedAt: Self.t0
        )
        #expect(!row.hasValidVector(expectedDimensions: 512))
    }

    /// A NaN would poison every later similarity comparison, silently.
    @Test("a vector containing NaN or infinity fails validation")
    func nonFiniteFailsValidation() {
        var withNaN = [Float](repeating: 0.1, count: 512)
        withNaN[7] = .nan
        #expect(
            !IndexSyncRow(
                localIdentifier: "a1", vector: withNaN,
                modelIdentifier: Self.model, indexedAt: Self.t0
            ).hasValidVector(expectedDimensions: 512)
        )

        var withInfinity = [Float](repeating: 0.1, count: 512)
        withInfinity[0] = .infinity
        #expect(
            !IndexSyncRow(
                localIdentifier: "a1", vector: withInfinity,
                modelIdentifier: Self.model, indexedAt: Self.t0
            ).hasValidVector(expectedDimensions: 512)
        )
    }

    /// A sync row carries a vector and metadata, never pixels. Asserted so the
    /// privacy boundary cannot be widened without a test failing.
    @Test("a sync row carries no image data")
    func syncRowCarriesNoPixels() {
        let row = IndexSyncRow(
            localIdentifier: "a1",
            vector: [Float](repeating: 0, count: 512),
            modelIdentifier: Self.model,
            indexedAt: Self.t0
        )
        // Reflection over the stored properties: if someone adds a Data or
        // image-shaped field, this fails and the privacy decision gets revisited
        // deliberately rather than by accident.
        let fields = Mirror(reflecting: row).children.compactMap(\.label)
        #expect(!fields.contains { $0.lowercased().contains("image") })
        #expect(!fields.contains { $0.lowercased().contains("thumbnail") })
        #expect(!fields.contains { $0.lowercased().contains("pixeldata") })
        for child in Mirror(reflecting: row).children {
            #expect(
                !(child.value is Data),
                "a sync row gained a Data field (\(child.label ?? "?")); pixels must not sync"
            )
        }
    }
}
