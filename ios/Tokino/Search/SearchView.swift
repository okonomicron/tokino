import Photos
import SwiftUI
import TokinoKit

/// Natural-language photo search.
///
/// The thing that makes Tokino feel like more than a scheduler: typing "seafood
/// rice bowl" and getting the right photos out of twenty thousand, with no
/// albums, tags or folders involved.
struct SearchView: View {
    @State private var model: SearchModel
    private let resolveLocalIdentifier: (Identifier<PhotoAsset>) -> String?

    init(
        model: SearchModel,
        resolveLocalIdentifier: @escaping (Identifier<PhotoAsset>) -> String?
    ) {
        self._model = State(initialValue: model)
        self.resolveLocalIdentifier = resolveLocalIdentifier
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Search")
                .searchable(
                    text: $model.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Try: seafood rice bowl"
                )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle:
            PromptView()

        case .searching:
            // A spinner rather than keeping stale results on screen: showing
            // the previous query's photos under a new query is worse than
            // showing nothing.
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .results(let results):
            ResultsGrid(results: results, resolveLocalIdentifier: resolveLocalIdentifier)

        case .empty(let explanation):
            ContentUnavailableView {
                Label("No photos found", systemImage: "photo.on.rectangle.angled")
            } description: {
                // The explanation distinguishes "nothing indexed" and "your
                // filters excluded everything" from "try different words".
                Text(explanation ?? "Try different words, or fewer of them.")
            }

        case .failed(let message):
            ContentUnavailableView {
                Label("Search failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }
}

private struct PromptView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Search your photos", systemImage: "sparkle.magnifyingglass")
        } description: {
            VStack(spacing: 10) {
                Text("Describe what you are looking for, in your own words.")
                Text("\"a seafood rice bowl\"  ·  \"a quiet street at night\"")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The results grid.
///
/// Thumbnails are loaded per cell and cancelled when a cell scrolls away,
/// because loading sixty full requests up front stalls the first paint.
private struct ResultsGrid: View {
    let results: [SearchResult]
    let resolveLocalIdentifier: (Identifier<PhotoAsset>) -> String?

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(results, id: \.assetID) { result in
                    ResultCell(
                        result: result,
                        localIdentifier: resolveLocalIdentifier(result.assetID)
                    )
                }
            }
            .padding(2)
        }
        .overlay(alignment: .top) {
            Text("\(results.count) photos")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 6)
        }
    }
}

private struct ResultCell: View {
    let result: SearchResult
    let localIdentifier: String?

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            // The similarity score, shown because it explains the ordering.
            // Without it a user cannot tell a strong match from a weak one that
            // merely came first.
            Text(String(format: "%.2f", result.score))
                .font(.caption2.monospacedDigit())
                .padding(3)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                .padding(3)
        }
        .task { await loadThumbnail() }
        .onDisappear {
            // Cancelled on scroll-away so a fast flick does not queue dozens of
            // requests that are no longer wanted.
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        }
        .accessibilityLabel("Photo, match score \(String(format: "%.2f", result.score))")
    }

    private func loadThumbnail() async {
        guard image == nil, let localIdentifier else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else { return }

        let options = PHImageRequestOptions()
        // Network access is allowed here, unlike during a scan: the user is
        // looking at this photo now, so fetching it is what they want.
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast

        let size = CGSize(width: 240, height: 240)
        image = await withCheckedContinuation { continuation in
            var resumed = false
            requestID = PHImageManager.default().requestImage(
                for: asset,
                targetSize: size,
                contentMode: .aspectFill,
                options: options
            ) { result, info in
                // .opportunistic can call back more than once, with a degraded
                // image first. Resume only on the final one, since resuming a
                // continuation twice traps.
                let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                guard !isDegraded, !resumed else { return }
                resumed = true
                continuation.resume(returning: result)
            }
        }
    }
}
