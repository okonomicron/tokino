import SwiftUI
import TokinoKit

/// First-run flow.
///
/// The ordering is the point. iOS shows the photo-library prompt **once per
/// install**, so asking before the user understands what we do with their
/// photos spends that single chance on an uninformed decision. The brief
/// requires explaining first, and it is also simply the right way round.
struct OnboardingView: View {
    @State private var model: OnboardingModel

    init(model: OnboardingModel = OnboardingModel()) {
        self._model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    privacyExplanation
                    Divider()
                    accessSection
                }
                .padding(24)
            }
            .navigationTitle("Welcome")
            .task { await model.refreshAccess() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tokino")
                .font(.largeTitle.bold())
            Text("Your memories. Your stories. Your voice.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        // One accessibility element: a screen reader should read this as a
        // title, not as two unrelated fragments.
        .accessibilityElement(children: .combine)
    }

    /// The explanation shown before the prompt.
    ///
    /// Concrete about what leaves the device, because "we respect your privacy"
    /// tells the user nothing and they have no reason to believe it.
    private var privacyExplanation: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("How Tokino uses your photos")
                .font(.headline)

            PrivacyPoint(
                symbol: "iphone",
                title: "Your photos stay on your iPhone",
                detail: """
                    Tokino reads your library to work out what is in each photo. \
                    That happens entirely on this device, and your pictures are \
                    not uploaded to do it.
                    """
            )
            PrivacyPoint(
                symbol: "number",
                title: "Only numbers are synced",
                detail: """
                    So Tokino can suggest posts while your phone is asleep, it \
                    syncs a short list of numbers describing each photo, plus \
                    details like the date and place. Those numbers cannot be \
                    turned back into a picture.
                    """
            )
            PrivacyPoint(
                symbol: "checkmark.seal",
                title: "A photo is only uploaded when you approve a post",
                detail: """
                    The one time a picture leaves your phone is when you have \
                    approved a post that uses it, and it needs to reach the \
                    social network.
                    """
            )
            PrivacyPoint(
                symbol: "hand.raised",
                title: "You stay in control",
                detail: """
                    You can exclude any photo or album, pause scanning at any \
                    time, and limit it to Wi-Fi.
                    """
            )
        }
    }

    @ViewBuilder
    private var accessSection: some View {
        switch model.access {
        case .notDetermined:
            VStack(alignment: .leading, spacing: 12) {
                Text("Ready when you are")
                    .font(.headline)
                Text("Next, iOS will ask whether Tokino can see your photos.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button {
                    Task { await model.requestAccess() }
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

        case .full:
            AccessStatusView(
                symbol: "checkmark.circle.fill",
                tint: .green,
                title: "Photo access granted",
                detail: "Tokino can index your whole library."
            )

        case .limited:
            // Not an error. The user made a deliberate choice, and everything
            // works over the photos they picked.
            VStack(alignment: .leading, spacing: 12) {
                AccessStatusView(
                    symbol: "checkmark.circle.fill",
                    tint: .green,
                    title: "Selected photos",
                    detail: """
                        Tokino will work with the photos you chose. You can add \
                        more at any time.
                        """
                )
                Button("Change selected photos") { model.openSettings() }
                    .buttonStyle(.bordered)
            }

        case .denied:
            VStack(alignment: .leading, spacing: 12) {
                AccessStatusView(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .orange,
                    title: "Photo access is off",
                    detail: """
                        Tokino needs to see your photos to find stories in them. \
                        You can turn this on in Settings.
                        """
                )
                Button("Open Settings") { model.openSettings() }
                    .buttonStyle(.borderedProminent)
            }

        case .restricted:
            // Offering Settings here would be misleading: the user cannot
            // change this themselves.
            AccessStatusView(
                symbol: "lock.fill",
                tint: .secondary,
                title: "Photo access is not available",
                detail: """
                    Access to photos is restricted on this device, probably by \
                    Screen Time or a device management profile.
                    """
            )
        }
    }
}

private struct PrivacyPoint: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28)
                // Decorative: the title beside it already carries the meaning,
                // so announcing the symbol would just be noise.
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct AccessStatusView: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    OnboardingView()
}
