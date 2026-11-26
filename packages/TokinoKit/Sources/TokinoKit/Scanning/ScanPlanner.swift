import Foundation

/// What PhotoKit reports about one library asset during enumeration.
///
/// Intentionally minimal: enumerating a 20,000-asset library must not pull
/// pixel data or force iCloud downloads (§2.2), so a snapshot carries only what
/// `PHAsset` gives up cheaply.
public struct LibraryAssetSnapshot: Sendable, Hashable {
    public let localIdentifier: String
    public let modificationDate: Date?
    public let isCloudOnly: Bool
    public let mediaKind: MediaKind

    public init(
        localIdentifier: String,
        modificationDate: Date? = nil,
        isCloudOnly: Bool = false,
        mediaKind: MediaKind = .image
    ) {
        self.localIdentifier = localIdentifier
        self.modificationDate = modificationDate
        self.isCloudOnly = isCloudOnly
        self.mediaKind = mediaKind
    }
}

/// What we have already indexed for one asset.
public struct IndexedAssetRecord: Sendable, Hashable {
    public let localIdentifier: String
    public let indexedAt: Date
    /// The asset's modification date as it was when we indexed it. Comparing
    /// against the library's current value is how we detect edits without
    /// re-embedding everything.
    public let sourceModificationDate: Date?
    /// Which embedding model produced the stored vector. A model upgrade
    /// re-indexes only assets on the old model.
    public let modelIdentifier: String

    public init(
        localIdentifier: String,
        indexedAt: Date,
        sourceModificationDate: Date? = nil,
        modelIdentifier: String
    ) {
        self.localIdentifier = localIdentifier
        self.indexedAt = indexedAt
        self.sourceModificationDate = sourceModificationDate
        self.modelIdentifier = modelIdentifier
    }
}

/// Device and user conditions that gate scanning (§2.2: respect battery,
/// network and storage; support Wi-Fi-only; allow the user to pause).
public struct ScanPolicy: Sendable, Hashable, Codable {
    public var batchSize: Int
    /// Skip assets not present on device rather than triggering an iCloud
    /// download. The brief forbids downloading the whole library.
    public var skipCloudOnlyAssets: Bool
    public var requiresWiFi: Bool
    /// 0...1. Below this, scanning waits.
    public var minimumBatteryLevel: Double
    public var allowsWhileLowPowerMode: Bool
    /// The embedding model we consider current. Records on another model are
    /// re-indexed.
    public var currentModelIdentifier: String

    public init(
        batchSize: Int = 200,
        skipCloudOnlyAssets: Bool = true,
        requiresWiFi: Bool = false,
        minimumBatteryLevel: Double = 0.2,
        allowsWhileLowPowerMode: Bool = false,
        currentModelIdentifier: String = "mobileclip-s2-v1"
    ) {
        self.batchSize = max(1, batchSize)
        self.skipCloudOnlyAssets = skipCloudOnlyAssets
        self.requiresWiFi = requiresWiFi
        self.minimumBatteryLevel = minimumBatteryLevel.clamped(to: 0...1)
        self.allowsWhileLowPowerMode = allowsWhileLowPowerMode
        self.currentModelIdentifier = currentModelIdentifier
    }
}

/// Observed device conditions at the moment we want to scan.
public struct DeviceConditions: Sendable, Hashable {
    public var batteryLevel: Double
    public var isCharging: Bool
    public var isOnWiFi: Bool
    public var isLowPowerModeEnabled: Bool
    public var availableStorageBytes: Int64
    /// The user's explicit pause switch, which overrides everything.
    public var isPausedByUser: Bool

    public init(
        batteryLevel: Double,
        isCharging: Bool,
        isOnWiFi: Bool,
        isLowPowerModeEnabled: Bool,
        availableStorageBytes: Int64,
        isPausedByUser: Bool = false
    ) {
        self.batteryLevel = batteryLevel.clamped(to: 0...1)
        self.isCharging = isCharging
        self.isOnWiFi = isOnWiFi
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
        self.availableStorageBytes = availableStorageBytes
        self.isPausedByUser = isPausedByUser
    }
}

/// Decides whether scanning may run right now, and says why not.
///
/// Separated from the planner so the UI can show the user a precise reason
/// ("waiting for Wi-Fi") instead of an indefinite spinner.
public enum ScanGate {
    public enum Verdict: Sendable, Hashable {
        case allowed
        case blocked(Reason)

        public var isAllowed: Bool {
            if case .allowed = self { return true }
            return false
        }
    }

    public enum Reason: String, Sendable, Hashable {
        case pausedByUser
        case batteryTooLow
        case lowPowerMode
        case waitingForWiFi
        case insufficientStorage
    }

    /// Minimum free space before we start writing thumbnails and vectors.
    public static let minimumRequiredStorageBytes: Int64 = 200 * 1_048_576

    public static func evaluate(
        conditions: DeviceConditions,
        policy: ScanPolicy
    ) -> Verdict {
        // The user's switch wins over every other consideration.
        if conditions.isPausedByUser { return .blocked(.pausedByUser) }

        if conditions.availableStorageBytes < minimumRequiredStorageBytes {
            return .blocked(.insufficientStorage)
        }

        // Charging makes battery level moot: the device is plugged in, which is
        // also when the system is most willing to run background work.
        if !conditions.isCharging && conditions.batteryLevel < policy.minimumBatteryLevel {
            return .blocked(.batteryTooLow)
        }

        if conditions.isLowPowerModeEnabled && !policy.allowsWhileLowPowerMode {
            return .blocked(.lowPowerMode)
        }

        if policy.requiresWiFi && !conditions.isOnWiFi {
            return .blocked(.waitingForWiFi)
        }

        return .allowed
    }
}

/// The work a scan needs to do, computed by diffing the library against what we
/// have already indexed.
public struct ScanPlan: Sendable, Hashable {
    /// Assets we have never seen.
    public let toIndex: [LibraryAssetSnapshot]
    /// Assets we have seen but that changed, or whose embedding is from an
    /// older model.
    public let toReindex: [LibraryAssetSnapshot]
    /// Identifiers we hold that are no longer in the library — deletions.
    public let toRemove: [String]
    /// Assets skipped because they live only in iCloud.
    public let skippedCloudOnly: [String]
    /// Count of assets needing no work. Reported so progress UI can show the
    /// true denominator rather than implying the whole library is being redone.
    public let unchangedCount: Int

    public var totalWorkItems: Int { toIndex.count + toReindex.count }
    public var hasWork: Bool { totalWorkItems > 0 || !toRemove.isEmpty }

    /// Work items in a stable order, new assets first.
    ///
    /// New assets before re-indexes because a first scan should show the user
    /// coverage of their library quickly; re-indexing an already-searchable
    /// asset is less urgent.
    public var orderedWorkItems: [LibraryAssetSnapshot] { toIndex + toReindex }

    /// Splits the work into batches for checkpointing.
    public func batches(size: Int) -> [[LibraryAssetSnapshot]] {
        let items = orderedWorkItems
        guard size > 0, !items.isEmpty else { return [] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}

/// Computes what a scan must do. Pure, so the whole incremental-scan contract
/// is testable without a photo library.
public enum ScanPlanner {

    /// Diff the library against our index.
    ///
    /// - Parameters:
    ///   - library: every asset currently visible to us.
    ///   - indexed: what we have already stored.
    ///   - policy: governs cloud-only skipping and model currency.
    public static func plan(
        library: [LibraryAssetSnapshot],
        indexed: [IndexedAssetRecord],
        policy: ScanPolicy
    ) -> ScanPlan {
        let indexedByID = Dictionary(
            indexed.map { ($0.localIdentifier, $0) },
            // A duplicate identifier in our own store is a bug upstream; keep
            // the most recently indexed one rather than crashing a user's scan.
            uniquingKeysWith: { $0.indexedAt >= $1.indexedAt ? $0 : $1 }
        )

        var toIndex: [LibraryAssetSnapshot] = []
        var toReindex: [LibraryAssetSnapshot] = []
        var skippedCloudOnly: [String] = []
        var unchangedCount = 0
        var seenInLibrary = Set<String>()

        for asset in library {
            // Guards against PhotoKit handing us the same asset twice, which
            // would otherwise double-index it (§2.2 "avoid duplicate indexing").
            guard seenInLibrary.insert(asset.localIdentifier).inserted else { continue }

            if asset.isCloudOnly && policy.skipCloudOnlyAssets {
                skippedCloudOnly.append(asset.localIdentifier)
                continue
            }

            guard let record = indexedByID[asset.localIdentifier] else {
                toIndex.append(asset)
                continue
            }

            if needsReindex(asset: asset, record: record, policy: policy) {
                toReindex.append(asset)
            } else {
                unchangedCount += 1
            }
        }

        // Anything we hold that the library no longer shows has been deleted or
        // is no longer permitted to us. Either way we drop our copy.
        //
        // Note: with limited photo-library access this also fires when the user
        // narrows their selection, which is the correct behaviour — we must not
        // retain an index for assets we can no longer see.
        // Deduplicated via a Set: a duplicate record in our own store would
        // otherwise produce the same removal twice, inflating the caller's
        // progress counts even though deleting twice is harmless.
        let toRemove = Set(indexed.map(\.localIdentifier))
            .subtracting(seenInLibrary)
            .sorted()

        return ScanPlan(
            toIndex: toIndex,
            toReindex: toReindex,
            toRemove: toRemove,
            skippedCloudOnly: skippedCloudOnly,
            unchangedCount: unchangedCount
        )
    }

    private static func needsReindex(
        asset: LibraryAssetSnapshot,
        record: IndexedAssetRecord,
        policy: ScanPolicy
    ) -> Bool {
        // An embedding from a superseded model cannot be compared against
        // vectors from the current one, so it must be redone.
        if record.modelIdentifier != policy.currentModelIdentifier { return true }

        switch (asset.modificationDate, record.sourceModificationDate) {
        case let (current?, stored?):
            return current > stored
        case (.some, .none):
            // We previously had no modification date and now do: treat as changed
            // rather than assume nothing happened.
            return true
        case (.none, .some), (.none, .none):
            // The library reports no modification date, so we have no evidence
            // of a change. Re-indexing on no evidence would mean rescanning the
            // library on every pass, which §2.2 forbids.
            return false
        }
    }
}
