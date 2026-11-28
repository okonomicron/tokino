import Foundation
import Photos
import TokinoKit
import UIKit

/// `PhotoLibraryReading` over PhotoKit.
///
/// The only place in the app that touches `PHAsset`. Everything above it works
/// against the protocol, which is what lets the scan logic be tested on Linux.
///
/// Two PhotoKit realities shape this type:
///
/// 1. **There is no "is this local?" property.** Cloud residency is only
///    discoverable by requesting an image with network access disabled and
///    reading `PHImageResultIsInCloudKey` from the result. So `isCloudOnly` is
///    always false in the snapshots this returns, and the cloud case surfaces
///    from `thumbnail(for:maxPixelSize:)` as `.deferredToCloud`.
/// 2. **Album membership is expensive.** Asking each asset which albums contain
///    it is O(assets x albums). Instead albums are enumerated once and inverted
///    into a lookup, which is one pass over each album's contents.
public final class PhotoKitLibrary: PhotoLibraryReading {

    private let imageManager: PHImageManager

    public init(imageManager: PHImageManager = .default()) {
        self.imageManager = imageManager
    }

    // MARK: - Enumeration

    public func enumerateAssets() async throws -> [LibraryAssetSnapshot] {
        let albumMembership = albumNamesByLocalIdentifier()

        let options = PHFetchOptions()
        // Oldest first, so a partial scan of a large library covers a
        // contiguous span of the user's history rather than a random slice.
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        options.includeHiddenAssets = false
        // Assets in the Recently Deleted album are on their way out; indexing
        // them would mean embedding work we then immediately prune.
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]

        let result = PHAsset.fetchAssets(with: options)
        var snapshots: [LibraryAssetSnapshot] = []
        snapshots.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            snapshots.append(
                LibraryAssetSnapshot(
                    localIdentifier: asset.localIdentifier,
                    modificationDate: asset.modificationDate,
                    // Always false: see this type's documentation. Cloud
                    // residency is discovered when fetching a thumbnail.
                    isCloudOnly: false,
                    mediaKind: asset.mediaType == .video ? .video : .image
                )
            )
            _ = albumMembership  // membership is attached by `metadata(for:)`
        }
        return snapshots
    }

    /// Richer metadata for assets the scan decided to index.
    ///
    /// Separate from enumeration because coordinates and album membership are
    /// only needed for assets we actually embed, and a 20,000-asset enumeration
    /// should stay cheap.
    public func metadata(for localIdentifiers: [String]) -> [String: PhotoAssetMetadata] {
        guard !localIdentifiers.isEmpty else { return [:] }

        let albumMembership = albumNamesByLocalIdentifier()
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)

        var metadata: [String: PhotoAssetMetadata] = [:]
        result.enumerateObjects { asset, _, _ in
            let coordinate = asset.location.map {
                Coordinate(
                    latitude: $0.coordinate.latitude,
                    longitude: $0.coordinate.longitude
                )
            }
            metadata[asset.localIdentifier] = PhotoAssetMetadata(
                createdAt: asset.creationDate,
                coordinate: coordinate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.mediaType == .video ? asset.duration : nil,
                albumNames: albumMembership[asset.localIdentifier] ?? [],
                mediaKind: asset.mediaType == .video ? .video : .image
            )
        }
        return metadata
    }

    /// Inverts albums into asset-to-album-names.
    ///
    /// `PHAsset` cannot tell you which albums contain it, so the only way is to
    /// walk each album. Done once per scan rather than once per asset.
    private func albumNamesByLocalIdentifier() -> [String: [String]] {
        var membership: [String: [String]] = [:]

        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        collections.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle else { return }
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            assets.enumerateObjects { asset, _, _ in
                membership[asset.localIdentifier, default: []].append(title)
            }
        }
        return membership
    }

    // MARK: - Thumbnails

    public func thumbnail(
        for localIdentifier: String,
        maxPixelSize: Int
    ) async throws -> ThumbnailOutcome {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            return .unavailable(reason: "asset no longer exists")
        }

        let options = PHImageRequestOptions()
        // The whole point: never pull from iCloud. The brief forbids
        // downloading the library, and a scan that silently used cellular data
        // would be a serious breach of trust.
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        // Synchronous within our own async context: the continuation below
        // expects exactly one callback, and .opportunistic delivery can call
        // back twice.
        options.isSynchronous = true
        options.resizeMode = .exact

        let targetSize = CGSize(width: maxPixelSize, height: maxPixelSize)

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFit,
                options: options
            ) { image, info in
                // Cloud residency is reported here, not as a property on the
                // asset. This is the documented way to detect it.
                let isInCloud = (info?[PHImageResultIsInCloudKey] as? Bool) ?? false

                guard let image else {
                    continuation.resume(
                        returning: isInCloud
                            ? .deferredToCloud
                            : .unavailable(reason: Self.failureReason(from: info))
                    )
                    return
                }

                // JPEG rather than PNG: an order of magnitude smaller for a
                // photograph, and the embedding model is unaffected by the
                // quantisation at this quality.
                guard let data = image.jpegData(compressionQuality: 0.9) else {
                    continuation.resume(returning: .unavailable(reason: "could not encode JPEG"))
                    return
                }
                continuation.resume(returning: .available(data))
            }
        }
    }

    private static func failureReason(from info: [AnyHashable: Any]?) -> String {
        if let error = info?[PHImageErrorKey] as? Error {
            return error.localizedDescription
        }
        if (info?[PHImageCancelledKey] as? Bool) == true {
            return "request cancelled"
        }
        return "no image returned"
    }

    // MARK: - Change tracking

    /// PhotoKit's persistent change token, as opaque bytes.
    ///
    /// This closes the open question from Milestone 1, which recorded
    /// `PHPersistentChangeToken` as an assumption because Apple's documentation
    /// endpoints returned 404 for the symbol. Compiling against the SDK is what
    /// settles it. If the API were absent this would not build, and the fallback
    /// is a full enumeration and diff — correct, just less efficient, which is
    /// what `ScanPlanner` already does.
    public func currentChangeToken() async -> Data? {
        let token = PHPhotoLibrary.shared().currentChangeToken
        return try? NSKeyedArchiver.archivedData(
            withRootObject: token,
            requiringSecureCoding: true
        )
    }

    /// Decodes a token previously stored in a checkpoint.
    public static func decodeChangeToken(_ data: Data) -> PHPersistentChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: PHPersistentChangeToken.self,
            from: data
        )
    }
}

/// Metadata attached to assets the scan indexes.
public struct PhotoAssetMetadata: Sendable, Hashable {
    public let createdAt: Date?
    public let coordinate: Coordinate?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval?
    public let albumNames: [String]
    public let mediaKind: MediaKind

    public init(
        createdAt: Date?,
        coordinate: Coordinate?,
        pixelWidth: Int,
        pixelHeight: Int,
        duration: TimeInterval?,
        albumNames: [String],
        mediaKind: MediaKind
    ) {
        self.createdAt = createdAt
        self.coordinate = coordinate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.albumNames = albumNames
        self.mediaKind = mediaKind
    }
}
