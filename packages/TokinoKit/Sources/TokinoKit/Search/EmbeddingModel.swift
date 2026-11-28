import Foundation

/// Describes an embedding model: what it produces, what it needs, and how to
/// verify the file you downloaded is the file we converted.
///
/// The weights are deliberately not bundled in the app. They are converted by
/// `tools/convert-openclip.py`, published as a release asset, and fetched during
/// onboarding. So a descriptor has to carry enough to download and verify them
/// without trusting the server.
public struct EmbeddingModelDescriptor: Sendable, Hashable, Codable {
    /// Written into every `PhotoEmbedding.modelIdentifier`, so changing it
    /// triggers a re-index of anything on the old model. Treat it as a version:
    /// any change to weights, precision or preprocessing needs a new value.
    public let identifier: String
    /// Output length. Must match `PhotoEmbedding.dimensions` and the
    /// `vector(512)` column in Postgres.
    public let dimensions: Int
    /// Longest edge the image tower expects, in pixels.
    public let inputPixelSize: Int
    /// Tokens the text tower expects, padded or truncated to exactly this.
    public let contextLength: Int
    /// Per-channel normalisation the model was trained with. Getting these
    /// wrong degrades every embedding in a way no crash reveals.
    public let pixelMean: [Float]
    public let pixelStandardDeviation: [Float]
    public let imageEncoder: Artifact
    public let textEncoder: Artifact
    /// SPDX identifier for the weights, recorded because the licence is the
    /// reason this model was chosen over the alternatives.
    public let weightsLicense: String
    public let weightsSource: String

    /// One downloadable file.
    public struct Artifact: Sendable, Hashable, Codable {
        public let fileName: String
        /// Lowercase hex SHA-256 of the archive. Verified before use: a model
        /// file is executable content as far as the Neural Engine is concerned,
        /// and we fetch it over the network.
        public let sha256: String
        public let byteCount: Int

        public init(fileName: String, sha256: String, byteCount: Int) {
            self.fileName = fileName
            self.sha256 = sha256
            self.byteCount = byteCount
        }
    }

    public init(
        identifier: String,
        dimensions: Int,
        inputPixelSize: Int,
        contextLength: Int,
        pixelMean: [Float],
        pixelStandardDeviation: [Float],
        imageEncoder: Artifact,
        textEncoder: Artifact,
        weightsLicense: String,
        weightsSource: String
    ) {
        self.identifier = identifier
        self.dimensions = dimensions
        self.inputPixelSize = inputPixelSize
        self.contextLength = contextLength
        self.pixelMean = pixelMean
        self.pixelStandardDeviation = pixelStandardDeviation
        self.imageEncoder = imageEncoder
        self.textEncoder = textEncoder
        self.weightsLicense = weightsLicense
        self.weightsSource = weightsSource
    }

    /// Whether this model's vectors can be compared with a stored embedding.
    ///
    /// Comparing across models is meaningless — the spaces are unrelated — so
    /// this is what drives the re-index decision rather than dimension alone.
    /// Two different 512-dimension models are still incompatible.
    public func canCompare(with storedModelIdentifier: String) -> Bool {
        identifier == storedModelIdentifier
    }
}

extension EmbeddingModelDescriptor {
    /// OpenCLIP ViT-B/32 trained on LAION-2B, converted to Core ML.
    ///
    /// Chosen over Apple's MobileCLIP because MobileCLIP's weights are
    /// research-only: its licence excludes "commercial exploitation, product
    /// development or use in any commercial product or service". These weights
    /// are MIT. See `docs/DECISIONS.md`.
    ///
    /// Chosen over SigLIP 2, which scores better, because SigLIP 2's text tower
    /// is 539 MB — its vocabulary is 256k tokens against OpenCLIP's 49,408 —
    /// and keeping search working offline matters more than the accuracy gap.
    ///
    /// Its 512 dimensions also happen to match the schema built in Milestone 1,
    /// so adopting it needs no migration.
    ///
    /// The checksums and byte counts come from an actual run of
    /// `tools/convert-openclip.py`, recorded in `build/models/manifest.json`.
    /// Together the two towers are about 137 MB, which is what the first-run
    /// download costs. Verified before use, because a model file is executable
    /// content as far as the Neural Engine is concerned and we fetch it over
    /// the network.
    public static let openCLIPViTB32 = EmbeddingModelDescriptor(
        identifier: "openclip-vit-b32-laion2b-v1",
        dimensions: 512,
        inputPixelSize: 224,
        contextLength: 77,
        // From the model's own open_clip_config.json rather than copied from a
        // blog post, because a wrong value here is invisible.
        pixelMean: [0.48145466, 0.4578275, 0.40821073],
        pixelStandardDeviation: [0.26862954, 0.26130258, 0.27577711],
        imageEncoder: Artifact(
            fileName: "openclip-vit-b32-image.mlpackage.zip",
            sha256: "5124c890fedd182d3ddc50bb1fb1ecb4867be8a6c0f65b274a7ad2417c1b8eb6",
            byteCount: 83006172
        ),
        textEncoder: Artifact(
            fileName: "openclip-vit-b32-text.mlpackage.zip",
            sha256: "5e3c34ee75e7fe920ff11b2750717361b2befcef0bf13cea8186275801c26d4c",
            byteCount: 60943205
        ),
        weightsLicense: "MIT",
        weightsSource: "https://huggingface.co/laion/CLIP-ViT-B-32-laion2B-s34B-b79K"
    )
}
