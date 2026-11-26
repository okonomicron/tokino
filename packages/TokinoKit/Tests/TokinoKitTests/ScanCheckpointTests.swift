import Foundation
import Testing
@testable import TokinoKit

/// Resumability and the gate conditions from §2.2. These matter because
/// `BGContinuedProcessingTask` can be terminated at any moment, so "resumes
/// correctly from a half-finished state" is the normal case, not an edge case.
@Suite("Scan checkpoint and gate")
struct ScanCheckpointTests {

    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func checkpoint(total: Int, phase: ScanCheckpoint.Phase = .indexing) -> ScanCheckpoint {
        ScanCheckpoint(phase: phase, totalWorkItems: total, startedAt: t0, updatedAt: t0)
    }

    // MARK: - Progress arithmetic

    @Test("progress starts at zero and reaches one")
    func progressBounds() {
        var cp = Self.checkpoint(total: 10)
        #expect(cp.fractionComplete == 0)

        cp.recordBatch(succeeded: (1...10).map { "a\($0)" }, at: Self.t0)
        #expect(cp.fractionComplete == 1)
        #expect(cp.remainingCount == 0)
    }

    @Test("an empty plan reports complete rather than dividing by zero")
    func emptyPlanProgress() {
        let indexing = Self.checkpoint(total: 0, phase: .indexing)
        #expect(indexing.fractionComplete == 0)

        let done = Self.checkpoint(total: 0, phase: .completed)
        #expect(done.fractionComplete == 1)
    }

    @Test("failures count toward settled work so progress cannot stall")
    func failuresAdvanceProgress() {
        var cp = Self.checkpoint(total: 4)
        cp.recordBatch(succeeded: ["a1"], failed: ["a2"], at: Self.t0)

        #expect(cp.completedIdentifiers == ["a1"])
        #expect(cp.failedIdentifiers == ["a2"])
        #expect(cp.settledCount == 2)
        #expect(cp.fractionComplete == 0.5)
    }

    /// Apple's docs say the system prioritises terminating continued-processing
    /// tasks that show minimal progress, so a stalled fraction is a real risk to
    /// the scan surviving, not just a UI nicety.
    @Test("a replayed batch does not inflate progress")
    func replayedBatchIsIdempotent() {
        var cp = Self.checkpoint(total: 10)
        cp.recordBatch(succeeded: ["a1", "a2"], at: Self.t0)
        cp.recordBatch(succeeded: ["a1", "a2"], at: Self.t0)

        #expect(cp.completedIdentifiers.count == 2)
        #expect(cp.fractionComplete == 0.2)
    }

    @Test("an item that later succeeds stops being marked failed")
    func retrySucceedingClearsFailure() {
        var cp = Self.checkpoint(total: 2)
        cp.recordBatch(succeeded: [], failed: ["a1"], at: Self.t0)
        #expect(cp.failedIdentifiers == ["a1"])

        cp.recordBatch(succeeded: ["a1"], at: Self.t0)
        #expect(cp.failedIdentifiers.isEmpty)
        #expect(cp.completedIdentifiers == ["a1"])
        #expect(cp.settledCount == 1, "the item must not be counted twice")
    }

    @Test("indexing advances to pruning once nothing remains")
    func phaseAdvancesWhenWorkDone() {
        var cp = Self.checkpoint(total: 2)
        cp.recordBatch(succeeded: ["a1"], at: Self.t0)
        #expect(cp.phase == .indexing)

        cp.recordBatch(succeeded: ["a2"], at: Self.t0)
        #expect(cp.phase == .pruning)
    }

    // MARK: - Resume

    /// The core resume property: after an interruption, only unfinished items
    /// are re-queued, and already-embedded assets are not redone.
    @Test("resuming re-queues only unsettled items")
    func resumeSkipsSettledWork() {
        let library = (1...10).map {
            LibraryAssetSnapshot(localIdentifier: "a\($0)")
        }
        let plan = ScanPlanner.plan(
            library: library,
            indexed: [],
            policy: ScanPolicy(currentModelIdentifier: "m1")
        )

        var cp = Self.checkpoint(total: plan.totalWorkItems)
        cp.recordBatch(succeeded: ["a1", "a2", "a3"], failed: ["a4"], at: Self.t0)

        let pending = cp.pendingItems(from: plan).map(\.localIdentifier)
        #expect(pending == ["a5", "a6", "a7", "a8", "a9", "a10"])
        #expect(!pending.contains("a4"), "a failed item is not retried in the same session")
    }

    /// A resumed session may build a fresh plan that contains assets the old one
    /// did not. Filtering by identifier rather than by stored index is what makes
    /// that safe.
    @Test("resume stays correct when the plan grew while we were away")
    func resumeHandlesGrownPlan() {
        var cp = Self.checkpoint(total: 3)
        cp.recordBatch(succeeded: ["a1"], at: Self.t0)

        // The user took two more photos while the app was closed.
        let grownPlan = ScanPlanner.plan(
            library: ["a1", "a2", "a3", "a4", "a5"].map { LibraryAssetSnapshot(localIdentifier: $0) },
            indexed: [],
            policy: ScanPolicy(currentModelIdentifier: "m1")
        )

        let pending = cp.pendingItems(from: grownPlan).map(\.localIdentifier)
        #expect(pending == ["a2", "a3", "a4", "a5"])
        #expect(!pending.contains("a1"), "already-embedded work must not be repeated")
    }

    @Test("a checkpoint survives a Codable round trip")
    func checkpointRoundTrips() throws {
        var cp = Self.checkpoint(total: 5)
        cp.recordBatch(succeeded: ["a1", "a2"], failed: ["a3"], at: Self.t0)
        cp.changeTokenData = Data([0x01, 0x02, 0x03])

        let data = try JSONEncoder().encode(cp)
        let decoded = try JSONDecoder().decode(ScanCheckpoint.self, from: data)

        #expect(decoded == cp)
        #expect(decoded.changeTokenData == Data([0x01, 0x02, 0x03]))
        #expect(decoded.fractionComplete == cp.fractionComplete)
    }

    @Test("terminal phases report as finished")
    func finishedPhases() {
        #expect(Self.checkpoint(total: 1, phase: .completed).isFinished)
        #expect(Self.checkpoint(total: 1, phase: .cancelled).isFinished)
        #expect(!Self.checkpoint(total: 1, phase: .indexing).isFinished)
        #expect(!Self.checkpoint(total: 1, phase: .enumerating).isFinished)
    }

    // MARK: - Estimates

    @Test("no time estimate is offered from too few samples")
    func noEstimateFromFewSamples() {
        var cp = Self.checkpoint(total: 1000)
        cp.recordBatch(succeeded: (1...5).map { "a\($0)" }, at: Self.t0.addingTimeInterval(5))

        let progress = ScanProgress(checkpoint: cp, now: Self.t0.addingTimeInterval(5))
        #expect(progress.estimatedTimeRemaining == nil, "5 samples is not enough to estimate from")
    }

    @Test("a time estimate appears once enough work has completed")
    func estimateAppearsWithEnoughSamples() throws {
        var cp = Self.checkpoint(total: 100)
        // 50 items in 50 seconds, so 1 s/item and 50 items left.
        cp.recordBatch(succeeded: (1...50).map { "a\($0)" }, at: Self.t0.addingTimeInterval(50))

        let progress = ScanProgress(checkpoint: cp, now: Self.t0.addingTimeInterval(50))
        let estimate = try #require(progress.estimatedTimeRemaining)
        #expect(abs(estimate - 50) < 0.001)
    }

    @Test("no estimate once there is nothing left to do")
    func noEstimateWhenComplete() {
        var cp = Self.checkpoint(total: 30)
        cp.recordBatch(succeeded: (1...30).map { "a\($0)" }, at: Self.t0.addingTimeInterval(30))
        let progress = ScanProgress(checkpoint: cp, now: Self.t0.addingTimeInterval(30))
        #expect(progress.estimatedTimeRemaining == nil)
    }

    // MARK: - Gate

    static func conditions(
        battery: Double = 0.9,
        charging: Bool = false,
        wifi: Bool = true,
        lowPower: Bool = false,
        storage: Int64 = 10 * 1_073_741_824,
        paused: Bool = false
    ) -> DeviceConditions {
        DeviceConditions(
            batteryLevel: battery,
            isCharging: charging,
            isOnWiFi: wifi,
            isLowPowerModeEnabled: lowPower,
            availableStorageBytes: storage,
            isPausedByUser: paused
        )
    }

    @Test("good conditions allow scanning")
    func gateAllowsHealthyDevice() {
        #expect(ScanGate.evaluate(conditions: Self.conditions(), policy: ScanPolicy()).isAllowed)
    }

    /// The user's pause switch must win over everything, including a device that
    /// is plugged in and idle (§2.2: allow users to pause automated scanning).
    @Test("the user's pause overrides even ideal conditions")
    func userPauseWins() {
        let verdict = ScanGate.evaluate(
            conditions: Self.conditions(battery: 1.0, charging: true, paused: true),
            policy: ScanPolicy()
        )
        #expect(verdict == .blocked(.pausedByUser))
    }

    @Test("a low battery blocks scanning")
    func lowBatteryBlocks() {
        let verdict = ScanGate.evaluate(
            conditions: Self.conditions(battery: 0.1),
            policy: ScanPolicy(minimumBatteryLevel: 0.2)
        )
        #expect(verdict == .blocked(.batteryTooLow))
    }

    /// Charging is when iOS is most willing to run background work, so a low
    /// battery on the charger must not block us.
    @Test("charging overrides a low battery")
    func chargingOverridesLowBattery() {
        let verdict = ScanGate.evaluate(
            conditions: Self.conditions(battery: 0.05, charging: true),
            policy: ScanPolicy(minimumBatteryLevel: 0.2)
        )
        #expect(verdict.isAllowed)
    }

    @Test("low power mode blocks unless the policy opts in")
    func lowPowerModeBlocks() {
        #expect(
            ScanGate.evaluate(
                conditions: Self.conditions(lowPower: true),
                policy: ScanPolicy(allowsWhileLowPowerMode: false)
            ) == .blocked(.lowPowerMode)
        )
        #expect(
            ScanGate.evaluate(
                conditions: Self.conditions(lowPower: true),
                policy: ScanPolicy(allowsWhileLowPowerMode: true)
            ).isAllowed
        )
    }

    @Test("Wi-Fi-only policy waits for Wi-Fi")
    func wifiOnlyPolicy() {
        #expect(
            ScanGate.evaluate(
                conditions: Self.conditions(wifi: false),
                policy: ScanPolicy(requiresWiFi: true)
            ) == .blocked(.waitingForWiFi)
        )
        #expect(
            ScanGate.evaluate(
                conditions: Self.conditions(wifi: false),
                policy: ScanPolicy(requiresWiFi: false)
            ).isAllowed
        )
    }

    @Test("insufficient storage blocks scanning")
    func storageBlocks() {
        let verdict = ScanGate.evaluate(
            conditions: Self.conditions(storage: 10 * 1_048_576),
            policy: ScanPolicy()
        )
        #expect(verdict == .blocked(.insufficientStorage))
    }
}
