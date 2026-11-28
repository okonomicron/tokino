import Foundation
import Network
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
    private let lock = NSLock()
    private var currentPath: NWPath?

    public init(isPausedByUser: @escaping @Sendable () -> Bool) {
        self.isPausedByUser = isPausedByUser
        self.pathMonitor = NWPathMonitor()

        // Battery level reads as -1 until monitoring is enabled, which would
        // look like a flat battery and block every scan.
        UIDevice.current.isBatteryMonitoringEnabled = true

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            currentPath = path
            lock.unlock()
        }
        pathMonitor.start(queue: DispatchQueue(label: "co.shinruey.tokino.network"))
    }

    deinit {
        pathMonitor.cancel()
    }

    public func currentConditions() async -> DeviceConditions {
        let device = UIDevice.current

        // A level of -1 means the value is not available yet. Treating that as
        // 0 would block scanning on a perfectly healthy device, so it is
        // reported as full and the charging check carries the decision.
        let rawLevel = device.batteryLevel
        let batteryLevel = rawLevel < 0 ? 1.0 : Double(rawLevel)

        let isCharging: Bool
        switch device.batteryState {
        case .charging, .full: isCharging = true
        case .unplugged, .unknown: isCharging = false
        @unknown default: isCharging = false
        }

        lock.lock()
        let path = currentPath
        lock.unlock()

        // Wi-Fi specifically, not merely "connected": the point of the
        // Wi-Fi-only policy is to avoid spending cellular data.
        let isOnWiFi = path?.usesInterfaceType(.wifi) ?? false

        return DeviceConditions(
            batteryLevel: batteryLevel,
            isCharging: isCharging,
            isOnWiFi: isOnWiFi,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            availableStorageBytes: Self.availableStorageBytes(),
            isPausedByUser: isPausedByUser()
        )
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
