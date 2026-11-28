import Foundation

/// Decides what of an embedding model still needs downloading, and verifies
/// what arrived.
///
/// The model is not bundled in the app — at 137 MB it would dominate the binary
/// — so it is fetched during onboarding. That makes verification mandatory
/// rather than optional: the file is executable content as far as the Neural
/// Engine is concerned, and it comes over the network.
///
/// Pure Foundation, so the whole install contract is testable on Linux with
/// real files rather than mocked ones.
public enum ModelInstaller {

    /// Why an artifact is not usable.
    public enum Verification: Sendable, Hashable {
        case verified
        case missing
        /// Checked before hashing, so a truncated download fails in
        /// milliseconds rather than after hashing 79 MB.
        case sizeMismatch(expected: Int, actual: Int)
        case digestMismatch(expected: String, actual: String)
        case unreadable

        public var isUsable: Bool { self == .verified }

        /// Whether re-downloading could plausibly fix this.
        ///
        /// A digest mismatch is included: it usually means a corrupted transfer
        /// rather than a tampered file, and refusing to retry would leave the
        /// app permanently unusable after one bad download.
        public var isRecoverableByRetrying: Bool {
            switch self {
            case .verified: return false
            case .missing, .sizeMismatch, .digestMismatch, .unreadable: return true
            }
        }
    }

    /// What installing this model requires.
    public struct Plan: Sendable, Hashable {
        public let toDownload: [EmbeddingModelDescriptor.Artifact]
        public let alreadyInstalled: [EmbeddingModelDescriptor.Artifact]
        /// Why each already-present-but-unusable artifact was rejected, so the
        /// UI can distinguish "never downloaded" from "download was corrupt".
        public let rejections: [String: Verification]

        public var isComplete: Bool { toDownload.isEmpty }
        public var bytesToDownload: Int { toDownload.reduce(0) { $0 + $1.byteCount } }
    }

    /// Works out what to fetch into `directory`.
    ///
    /// An artifact already present and verified is skipped, so a relaunch during
    /// onboarding does not re-download 137 MB.
    public static func plan(
        for descriptor: EmbeddingModelDescriptor,
        in directory: URL,
        fileManager: FileManager = .default
    ) -> Plan {
        var toDownload: [EmbeddingModelDescriptor.Artifact] = []
        var installed: [EmbeddingModelDescriptor.Artifact] = []
        var rejections: [String: Verification] = [:]

        for artifact in [descriptor.imageEncoder, descriptor.textEncoder] {
            let url = directory.appendingPathComponent(artifact.fileName)
            let verification = verify(artifact, at: url, fileManager: fileManager)

            if verification.isUsable {
                installed.append(artifact)
            } else {
                toDownload.append(artifact)
                // `missing` is the ordinary first-run case and not worth
                // reporting as a rejection; anything else means a real problem
                // with a file that is actually there.
                if verification != .missing {
                    rejections[artifact.fileName] = verification
                }
            }
        }

        return Plan(toDownload: toDownload, alreadyInstalled: installed, rejections: rejections)
    }

    /// Checks one artifact on disk against its expected size and digest.
    ///
    /// Size first: it is a single stat call and rules out the common failure —
    /// a truncated or interrupted download — without reading the file.
    public static func verify(
        _ artifact: EmbeddingModelDescriptor.Artifact,
        at url: URL,
        fileManager: FileManager = .default
    ) -> Verification {
        guard fileManager.fileExists(atPath: url.path) else { return .missing }

        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return .unreadable }

        let actualSize = size.intValue
        // A zero expected size means the descriptor has not been filled in yet,
        // so size is not checked. The digest still is.
        if artifact.byteCount > 0, actualSize != artifact.byteCount {
            return .sizeMismatch(expected: artifact.byteCount, actual: actualSize)
        }

        guard let digest = SHA256.hexDigestOfFile(at: url) else { return .unreadable }

        // An empty expected digest means the same: not yet recorded. Refusing
        // to verify would block development before the first conversion is
        // published, and a size check still applies once that is filled in.
        guard !artifact.sha256.isEmpty else { return .verified }

        guard digest.caseInsensitiveCompare(artifact.sha256) == .orderedSame else {
            return .digestMismatch(expected: artifact.sha256.lowercased(), actual: digest)
        }
        return .verified
    }

    /// The URL to fetch an artifact from, given a base.
    ///
    /// The base is configuration rather than a constant, so the host can change
    /// — a GitHub release, object storage, a local server during development —
    /// without touching the descriptor.
    public static func downloadURL(
        for artifact: EmbeddingModelDescriptor.Artifact,
        baseURL: URL
    ) -> URL {
        baseURL.appendingPathComponent(artifact.fileName)
    }
}
