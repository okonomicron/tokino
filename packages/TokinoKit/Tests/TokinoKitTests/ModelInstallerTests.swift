import Foundation
import Testing
@testable import TokinoKit

/// Tested against real files in a temporary directory rather than a mocked
/// filesystem, because the behaviour that matters — a truncated download, a
/// corrupted byte, a relaunch part-way through onboarding — is about what is
/// actually on disk.
@Suite("Model installer")
struct ModelInstallerTests {

    /// A scratch directory per test, cleaned up afterwards.
    final class Workspace {
        let url: URL

        init() {
            url = FileManager.default.temporaryDirectory
                .appendingPathComponent("tokino-installer-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }

        /// Writes a file and returns an artifact describing it truthfully.
        func write(
            _ name: String,
            bytes: [UInt8]
        ) -> EmbeddingModelDescriptor.Artifact {
            let path = url.appendingPathComponent(name)
            try? Data(bytes).write(to: path)
            return EmbeddingModelDescriptor.Artifact(
                fileName: name,
                sha256: SHA256.hexDigest(of: bytes),
                byteCount: bytes.count
            )
        }
    }

    static func bytes(_ count: Int, seed: UInt8 = 1) -> [UInt8] {
        (0..<count).map { UInt8(($0 &* Int(seed) &+ 7) % 256) }
    }

    static func descriptor(
        image: EmbeddingModelDescriptor.Artifact,
        text: EmbeddingModelDescriptor.Artifact
    ) -> EmbeddingModelDescriptor {
        EmbeddingModelDescriptor(
            identifier: "test-model-v1",
            dimensions: 512,
            inputPixelSize: 224,
            contextLength: 77,
            pixelMean: [0, 0, 0],
            pixelStandardDeviation: [1, 1, 1],
            imageEncoder: image,
            textEncoder: text,
            weightsLicense: "MIT",
            weightsSource: "https://example.test"
        )
    }

    // MARK: - Verification

    @Test("a correct file verifies")
    func correctFileVerifies() {
        let workspace = Workspace()
        let artifact = workspace.write("image.zip", bytes: Self.bytes(5_000))

        let result = ModelInstaller.verify(
            artifact,
            at: workspace.url.appendingPathComponent(artifact.fileName)
        )
        #expect(result == .verified)
        #expect(result.isUsable)
    }

    @Test("a missing file is reported as missing, not as corrupt")
    func missingFile() {
        let workspace = Workspace()
        let artifact = EmbeddingModelDescriptor.Artifact(
            fileName: "absent.zip",
            sha256: String(repeating: "a", count: 64),
            byteCount: 100
        )

        let result = ModelInstaller.verify(
            artifact,
            at: workspace.url.appendingPathComponent(artifact.fileName)
        )
        #expect(result == .missing)
        // The distinction matters: "never downloaded" and "download was
        // corrupt" deserve different messages.
        #expect(result.isRecoverableByRetrying)
    }

    /// The common real failure — an interrupted download. Caught by size
    /// before hashing, so it costs a stat rather than reading 79 MB.
    @Test("a truncated file is caught on size, before hashing")
    func truncatedFileCaughtOnSize() {
        let workspace = Workspace()
        let full = Self.bytes(10_000)
        let artifact = EmbeddingModelDescriptor.Artifact(
            fileName: "truncated.zip",
            sha256: SHA256.hexDigest(of: full),
            byteCount: full.count
        )
        // Write only part of it.
        try? Data(full.prefix(4_000)).write(
            to: workspace.url.appendingPathComponent(artifact.fileName)
        )

        let result = ModelInstaller.verify(
            artifact,
            at: workspace.url.appendingPathComponent(artifact.fileName)
        )
        #expect(result == .sizeMismatch(expected: 10_000, actual: 4_000))
    }

    /// Right length, wrong contents. Only the digest catches this.
    @Test("a corrupted file of the right size is caught on digest")
    func corruptedFileCaughtOnDigest() {
        let workspace = Workspace()
        var corrupted = Self.bytes(8_000)
        let expectedDigest = SHA256.hexDigest(of: corrupted)
        corrupted[4_000] ^= 0xFF

        let artifact = EmbeddingModelDescriptor.Artifact(
            fileName: "corrupt.zip",
            sha256: expectedDigest,
            byteCount: corrupted.count
        )
        try? Data(corrupted).write(
            to: workspace.url.appendingPathComponent(artifact.fileName)
        )

        let result = ModelInstaller.verify(
            artifact,
            at: workspace.url.appendingPathComponent(artifact.fileName)
        )
        guard case .digestMismatch(let expected, let actual) = result else {
            Issue.record("expected a digest mismatch, got \(result)")
            return
        }
        #expect(expected == expectedDigest)
        #expect(actual != expectedDigest)
    }

    @Test("digest comparison ignores hex case")
    func digestComparisonIsCaseInsensitive() {
        let workspace = Workspace()
        let data = Self.bytes(1_000)
        let artifact = EmbeddingModelDescriptor.Artifact(
            fileName: "upper.zip",
            sha256: SHA256.hexDigest(of: data).uppercased(),
            byteCount: data.count
        )
        try? Data(data).write(to: workspace.url.appendingPathComponent(artifact.fileName))

        #expect(
            ModelInstaller.verify(
                artifact,
                at: workspace.url.appendingPathComponent(artifact.fileName)
            ) == .verified
        )
    }

    /// Placeholders exist before the first conversion is published. Refusing to
    /// verify then would block development entirely.
    @Test("an unrecorded digest or size skips that check rather than failing")
    func placeholderDescriptorIsTolerated() {
        let workspace = Workspace()
        let data = Self.bytes(2_000)
        let artifact = EmbeddingModelDescriptor.Artifact(
            fileName: "placeholder.zip",
            sha256: "",
            byteCount: 0
        )
        try? Data(data).write(to: workspace.url.appendingPathComponent(artifact.fileName))

        #expect(
            ModelInstaller.verify(
                artifact,
                at: workspace.url.appendingPathComponent(artifact.fileName)
            ) == .verified
        )
    }

    /// An empty file is a real failure mode: a server returning 200 with no
    /// body. The size check must catch it rather than hashing nothing happily.
    @Test("an empty file fails rather than verifying")
    func emptyFileFails() {
        let workspace = Workspace()
        let artifact = EmbeddingModelDescriptor.Artifact(
            fileName: "empty.zip",
            sha256: SHA256.hexDigest(of: Self.bytes(100)),
            byteCount: 100
        )
        try? Data().write(to: workspace.url.appendingPathComponent(artifact.fileName))

        let result = ModelInstaller.verify(
            artifact,
            at: workspace.url.appendingPathComponent(artifact.fileName)
        )
        #expect(result == .sizeMismatch(expected: 100, actual: 0))
    }

    // MARK: - Planning

    @Test("a first run plans to download both towers")
    func firstRunDownloadsBoth() {
        let workspace = Workspace()
        let descriptor = Self.descriptor(
            image: EmbeddingModelDescriptor.Artifact(
                fileName: "image.zip", sha256: String(repeating: "b", count: 64), byteCount: 500
            ),
            text: EmbeddingModelDescriptor.Artifact(
                fileName: "text.zip", sha256: String(repeating: "c", count: 64), byteCount: 300
            )
        )

        let plan = ModelInstaller.plan(for: descriptor, in: workspace.url)
        #expect(plan.toDownload.count == 2)
        #expect(plan.alreadyInstalled.isEmpty)
        #expect(plan.bytesToDownload == 800)
        #expect(!plan.isComplete)
        // Absent files are the ordinary case and are not reported as problems.
        #expect(plan.rejections.isEmpty)
    }

    /// A relaunch part-way through onboarding must not re-download 137 MB.
    @Test("an already-installed model plans no work")
    func installedModelNeedsNoWork() {
        let workspace = Workspace()
        let image = workspace.write("image.zip", bytes: Self.bytes(4_000, seed: 3))
        let text = workspace.write("text.zip", bytes: Self.bytes(2_000, seed: 5))

        let plan = ModelInstaller.plan(
            for: Self.descriptor(image: image, text: text),
            in: workspace.url
        )
        #expect(plan.isComplete)
        #expect(plan.toDownload.isEmpty)
        #expect(plan.alreadyInstalled.count == 2)
        #expect(plan.bytesToDownload == 0)
    }

    @Test("a half-installed model downloads only what is missing")
    func halfInstalledDownloadsRemainder() {
        let workspace = Workspace()
        let image = workspace.write("image.zip", bytes: Self.bytes(4_000, seed: 3))
        let text = EmbeddingModelDescriptor.Artifact(
            fileName: "text.zip", sha256: String(repeating: "d", count: 64), byteCount: 1_234
        )

        let plan = ModelInstaller.plan(
            for: Self.descriptor(image: image, text: text),
            in: workspace.url
        )
        #expect(plan.toDownload.map(\.fileName) == ["text.zip"])
        #expect(plan.alreadyInstalled.map(\.fileName) == ["image.zip"])
        #expect(plan.bytesToDownload == 1_234)
    }

    /// A corrupt file must be re-downloaded *and* reported, so the UI can say
    /// "that download was damaged" rather than silently starting again.
    @Test("a corrupt installed file is re-planned and reported")
    func corruptFileIsReplannedAndReported() {
        let workspace = Workspace()
        let good = workspace.write("text.zip", bytes: Self.bytes(2_000, seed: 5))

        var bytes = Self.bytes(4_000, seed: 3)
        let digest = SHA256.hexDigest(of: bytes)
        bytes[10] ^= 0xAA
        try? Data(bytes).write(to: workspace.url.appendingPathComponent("image.zip"))
        let image = EmbeddingModelDescriptor.Artifact(
            fileName: "image.zip", sha256: digest, byteCount: bytes.count
        )

        let plan = ModelInstaller.plan(
            for: Self.descriptor(image: image, text: good),
            in: workspace.url
        )
        #expect(plan.toDownload.map(\.fileName) == ["image.zip"])
        #expect(plan.rejections.keys.contains("image.zip"))
        guard case .digestMismatch = plan.rejections["image.zip"] else {
            Issue.record("expected a digest mismatch, got \(String(describing: plan.rejections["image.zip"]))")
            return
        }
    }

    @Test("planning in a directory that does not exist downloads everything")
    func missingDirectoryPlansFullDownload() {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("tokino-absent-\(UUID().uuidString)")
        let descriptor = Self.descriptor(
            image: EmbeddingModelDescriptor.Artifact(
                fileName: "image.zip", sha256: String(repeating: "b", count: 64), byteCount: 1
            ),
            text: EmbeddingModelDescriptor.Artifact(
                fileName: "text.zip", sha256: String(repeating: "c", count: 64), byteCount: 1
            )
        )

        let plan = ModelInstaller.plan(for: descriptor, in: absent)
        #expect(plan.toDownload.count == 2)
        #expect(plan.rejections.isEmpty)
    }

    // MARK: - URLs

    @Test("a download URL is the base plus the file name")
    func downloadURLComposition() {
        let base = URL(string: "https://example.test/models/v1")!
        let artifact = EmbeddingModelDescriptor.Artifact(
            fileName: "openclip-vit-b32-image.mlpackage.zip", sha256: "", byteCount: 0
        )
        #expect(
            ModelInstaller.downloadURL(for: artifact, baseURL: base).absoluteString
                == "https://example.test/models/v1/openclip-vit-b32-image.mlpackage.zip"
        )
    }

    // MARK: - The shipped descriptor

    /// The real descriptor must be internally consistent with the schema and
    /// the tokenizer, or the app would fail at its first embedding.
    @Test("the shipped OpenCLIP descriptor is self-consistent")
    func shippedDescriptorIsConsistent() {
        let model = EmbeddingModelDescriptor.openCLIPViTB32

        #expect(model.dimensions == PhotoEmbedding.dimensions)
        #expect(model.contextLength == CLIPTokenizer.contextLength)
        #expect(model.inputPixelSize == 224)
        #expect(model.weightsLicense == "MIT")
        #expect(model.pixelMean.count == 3)
        #expect(model.pixelStandardDeviation.count == 3)
        #expect(model.pixelStandardDeviation.allSatisfy { $0 > 0 }, "a zero would divide by zero")

        // Filled in from a real conversion, so these are no longer placeholders.
        #expect(model.imageEncoder.sha256.count == 64)
        #expect(model.textEncoder.sha256.count == 64)
        #expect(model.imageEncoder.byteCount > 0)
        #expect(model.textEncoder.byteCount > 0)
        #expect(model.imageEncoder.sha256 != model.textEncoder.sha256)
    }

    @Test("comparing across models is refused even at equal dimensions")
    func crossModelComparisonRefused() {
        let model = EmbeddingModelDescriptor.openCLIPViTB32
        #expect(model.canCompare(with: model.identifier))
        // Another 512-dimension model is still a different space.
        #expect(!model.canCompare(with: "some-other-512-dim-model"))
    }
}
