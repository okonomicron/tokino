import Foundation
import Network
import os
import TokinoKit
import UIKit

/// Reports the real device conditions `ScanGate` checks between batches.
///
/// Read fresh each time rather than cached, because all four of these change
/// during a long scan: the phone gets unplugged, the battery drains, Wi-Fi
/// drops as the user walks out of the house, and they may hit pause.
public final class DeviceConditionsMonitor: DeviceConditionsProviding, @unchecked Sendable {

    /// The user's pause switch. Stored outside this type so it survives a
    /// relaunch; this only reads it.
    private let isPausedByUser: @Sendable () -> Bool
    private let pathMonitor: NWPathMonitor

    /// Whether the current path is Wi-Fi.
    ///
    /// `OSAllocatedUnfairLock` rather than `NSLock`: the latter's `lock()` is
    /// unavailable from async contexts, and this is read from one. Storing the
    /// single boolean rather than the whole `NWPath` also keeps the state
    /// trivially `Sendable`.
    private let isOnWiFiStorage = OSAllocatedUnfairLock<Bool>(initialState: false)

    public init(isPausedByUser: @escaping @Sendable () -> Bool) {
        self.isPausedByUser = isPausedByUser
        self.pathMonitor = NWPathMonitor()

        // Battery level reads as -1 until monitoring is enabled, which would
        // look like a flat battery and block every scan. UIDevice is
        // main-actor isolated, so this hops rather than touching it here.
        Task { @MainActor in
            UIDevice.current.isBatteryMonitoringEnabled = true
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            // Wi-Fi specifically, not merely "connected": the point of the
            // Wi-Fi-only policy is to avoid spending the user's cellular data.
            self?.isOnWiFiStorage.withLock { $0 = path.usesInterfaceType(.wifi) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "co.shinruey.tokino.network"))
    }

    deinit {
        pathMonitor.cancel()
    }

    public func currentConditions() async -> DeviceConditions {
        // UIDevice is main-actor isolated, so battery state is read there and
        // the plain values come back. Everything else below is actor-agnostic.
        let battery = await MainActor.run { Self.readBattery() }

        let isOnWiFi = isOnWiFiStorage.withLock { $0 }

        return DeviceConditions(
            batteryLevel: battery.level,
            isCharging: battery.isCharging,
            isOnWiFi: isOnWiFi,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            availableStorageBytes: Self.availableStorageBytes(),
            isPausedByUser: isPausedByUser()
        )
    }

    /// Battery level and charging state, as plain `Sendable` values.
    @MainActor
    private static func readBattery() -> (level: Double, isCharging: Bool) {
        let device = UIDevice.current

        // A level of -1 means the value is not available yet. Treating it as 0
        // would block scanning on a perfectly healthy device, so it reads as
        // full and the charging check carries the decision.
        let rawLevel = device.batteryLevel
        let level = rawLevel < 0 ? 1.0 : Double(rawLevel)

        let isCharging: Bool
        switch device.batteryState {
        case .charging, .full: isCharging = true
        case .unplugged, .unknown: isCharging = false
        @unknown default: isCharging = false
        }
        return (level, isCharging)
    }

    /// Free space, as the system would report it for a download the user wants.
    ///
    /// `volumeAvailableCapacityForImportantUsage` rather than the raw free
    /// space, because it accounts for purgeable caches the system will reclaim —
    /// the raw figure can read as nearly full on a device that has plenty of
    /// room for us.
    private static func availableStorageBytes() -> Int64 {
        let url = URL.documentsDirectory
        do {
            let values = try url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            )
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return Int64(capacity)
            }
        } catch {
            // Fall through: an unreadable volume should not permanently block
            // scanning, and the real failure will surface as a write error.
        }
        return Int64.max
    }
}
