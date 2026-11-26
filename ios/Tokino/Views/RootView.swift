import SwiftUI
import TokinoKit

/// Milestone 1 placeholder.
///
/// Its purpose is structural, not visual: it proves the app target links
/// TokinoKit and that the generated project builds and runs on a simulator in
/// CI. The real screens arrive in Milestone 2, so there is deliberately no
/// product design here yet.
struct RootView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Foundation") {
                    LabeledContent("Milestone", value: "1 — foundation")
                    LabeledContent("Platforms", value: platformSummary)
                    LabeledContent("Publishing", value: publishingSummary)
                }

                Section("Scan readiness") {
                    // Exercises real TokinoKit logic, so a linkage or
                    // behaviour regression shows up as a visible wrong value
                    // rather than only in a unit test.
                    LabeledContent("Idle device", value: verdictDescription(for: idleConditions))
                    LabeledContent("Low battery", value: verdictDescription(for: lowBatteryConditions))
                }
            }
            .navigationTitle("Tokino")
        }
    }

    private var platformSummary: String {
        Platform.allCases.map(\.displayName).joined(separator: ", ")
    }

    private var publishingSummary: String {
        let api = Platform.allCases.filter { $0.publishingMode == .officialAPI }
        return "\(api.count) of \(Platform.allCases.count) via official API"
    }

    private var idleConditions: DeviceConditions {
        DeviceConditions(
            batteryLevel: 0.9,
            isCharging: true,
            isOnWiFi: true,
            isLowPowerModeEnabled: false,
            availableStorageBytes: 8 * 1_073_741_824
        )
    }

    private var lowBatteryConditions: DeviceConditions {
        DeviceConditions(
            batteryLevel: 0.05,
            isCharging: false,
            isOnWiFi: true,
            isLowPowerModeEnabled: false,
            availableStorageBytes: 8 * 1_073_741_824
        )
    }

    private func verdictDescription(for conditions: DeviceConditions) -> String {
        switch ScanGate.evaluate(conditions: conditions, policy: ScanPolicy()) {
        case .allowed:
            return "Ready"
        case .blocked(let reason):
            return "Waiting: \(reason.rawValue)"
        }
    }
}

#Preview {
    RootView()
}
