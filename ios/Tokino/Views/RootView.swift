import SwiftUI
import TokinoKit

/// The app's root.
///
/// Shows onboarding until the photo library is readable, then the main
/// experience. Deliberately a simple switch: the real tab structure arrives
/// with the screens that need it, and inventing it now would be scaffolding
/// with nothing to hold.
struct RootView: View {
    @State private var authorization = PhotoLibraryAuthorization()
    @State private var access: PhotoLibraryAccess = .notDetermined

    var body: some View {
        Group {
            if access.canReadLibrary {
                LibraryPlaceholderView(access: access)
            } else {
                OnboardingView()
            }
        }
        .task { access = authorization.currentAccess() }
        // Re-checked on foreground: the user may have changed permission in
        // Settings while the app was in the background.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { access = authorization.currentAccess() }
        }
    }

    @Environment(\.scenePhase) private var scenePhase
}

/// Stands in for the library and search screens, which land next.
///
/// It is not empty: it exercises real TokinoKit logic, so a linkage or
/// behaviour regression shows up as a visibly wrong value rather than only in
/// a unit test.
private struct LibraryPlaceholderView: View {
    let access: PhotoLibraryAccess

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Milestone", value: "2a — photo discovery")
                    LabeledContent("Photo access", value: accessDescription)
                    LabeledContent("Embedding model", value: model.identifier)
                    LabeledContent("Dimensions", value: "\(model.dimensions)")
                    LabeledContent("Weights licence", value: model.weightsLicense)
                }

                Section("Tokenizer") {
                    // Proves the bundled vocabulary and merges load on device,
                    // not just on Linux.
                    LabeledContent("Query", value: sampleQuery)
                    LabeledContent("Tokens", value: tokenSummary)
                }

                Section("Scan readiness") {
                    LabeledContent("Idle and charging", value: verdict(for: idleConditions))
                    LabeledContent("Low battery", value: verdict(for: lowBatteryConditions))
                }
            }
            .navigationTitle("Tokino")
        }
    }

    private let model = EmbeddingModelDescriptor.openCLIPViTB32
    private let sampleQuery = "a photo of kaisendon"

    private var accessDescription: String {
        switch access {
        case .full: return "Full library"
        case .limited: return "Selected photos"
        case .notDetermined: return "Not asked"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }

    private var tokenSummary: String {
        guard let tokenizer = try? CLIPTokenizer() else { return "unavailable" }
        let tokens = tokenizer.encode(sampleQuery)
        return "\(tokens.count) tokens"
    }

    private var idleConditions: DeviceConditions {
        DeviceConditions(
            batteryLevel: 0.9, isCharging: true, isOnWiFi: true,
            isLowPowerModeEnabled: false, availableStorageBytes: 8 * 1_073_741_824
        )
    }

    private var lowBatteryConditions: DeviceConditions {
        DeviceConditions(
            batteryLevel: 0.05, isCharging: false, isOnWiFi: true,
            isLowPowerModeEnabled: false, availableStorageBytes: 8 * 1_073_741_824
        )
    }

    private func verdict(for conditions: DeviceConditions) -> String {
        switch ScanGate.evaluate(conditions: conditions, policy: ScanPolicy()) {
        case .allowed: return "Ready"
        case .blocked(let reason): return "Waiting: \(reason.rawValue)"
        }
    }
}

#Preview {
    RootView()
}
