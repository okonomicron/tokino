import Accelerate
import CoreML
import Foundation
import TokinoKit
import UIKit

/// Runs the OpenCLIP towers on-device via Core ML.
///
/// Why on-device at all: it is the decision that makes the product's economics
/// work. Indexing a 20,000-photo library costs nothing and no photograph leaves
/// the phone. Cloud vision over a whole library would be the single largest
/// operating cost in Tokino, and the privacy story would be much weaker.
///
/// Two towers, loaded independently. The image tower runs once per photo during
/// a scan; the text tower runs once per search query. Loading the text tower
/// lazily means a scan does not pay for it.
///
/// **Not an actor**, which was the first instinct. `MLModel` and
/// `MLDictionaryFeatureProvider` are not `Sendable`, so an actor cannot call
/// into them: every prediction would "send" a non-Sendable value across the
/// isolation boundary, which Swift 6 rejects. A class keeps the model inside a
/// single context.
///
/// `@unchecked Sendable` is justified rather than convenient: Apple documents
/// `MLModel` prediction as thread-safe, and the only mutable state here is the
/// two lazily-loaded handles, which the lock guards. The lock is never held
/// across a prediction, so concurrent embedding still runs in parallel.
public final class CoreMLEmbedder: ImageEmbedding, @unchecked Sendable {

    public enum EmbedderError: Error, CustomStringConvertible {
        case modelMissing(String)
        case imageDecodeFailed
        case unexpectedOutput(String)

        public var description: String {
            switch self {
            case .modelMissing(let path):
                return "Embedding model not found at \(path). It is downloaded during onboarding."
            case .imageDecodeFailed:
                return "Could not decode the image data into pixels."
            case .unexpectedOutput(let detail):
                return "The model produced an unexpected output: \(detail)"
            }
        }
    }

    private let descriptor: EmbeddingModelDescriptor
    private let imageModelURL: URL
    private let textModelURL: URL

    private var imageModel: MLModel?
    private var textModel: MLModel?

    public var modelIdentifier: String { descriptor.identifier }
    public var dimensions: Int { descriptor.dimensions }
    public var preferredInputPixelSize: Int { descriptor.inputPixelSize }

    public init(
        descriptor: EmbeddingModelDescriptor,
        imageModelURL: URL,
        textModelURL: URL
    ) {
        self.descriptor = descriptor
        self.imageModelURL = imageModelURL
        self.textModelURL = textModelURL
    }

    // MARK: - Model loading

    private func configuration() -> MLModelConfiguration {
        let configuration = MLModelConfiguration()
        // .all lets Core ML use the Neural Engine, which is the whole point:
        // the ANE is both far faster and far more power-efficient than the CPU
        // for this, and a library scan is thousands of inferences.
        configuration.computeUnits = .all
        return configuration
    }

    private func loadImageModel() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let imageModel { return imageModel }

        guard FileManager.default.fileExists(atPath: imageModelURL.path) else {
            throw EmbedderError.modelMissing(imageModelURL.path)
        }
        // compileModel is required for a downloaded .mlpackage: Core ML needs a
        // compiled .mlmodelc, and shipping the compiled form is not portable
        // across OS versions.
        let compiled = try MLModel.compileModel(at: imageModelURL)
        let model = try MLModel(contentsOf: compiled, configuration: configuration())
        imageModel = model
        return model
    }

    private func loadTextModel() throws -> MLModel {
        lock.lock()
        defer { lock.unlock() }
        if let textModel { return textModel }

        guard FileManager.default.fileExists(atPath: textModelURL.path) else {
            throw EmbedderError.modelMissing(textModelURL.path)
        }
        let compiled = try MLModel.compileModel(at: textModelURL)
        let model = try MLModel(contentsOf: compiled, configuration: configuration())
        textModel = model
        return model
    }

    /// Loads both towers up front, so a scan does not stall on first use and a
    /// missing model is reported during onboarding rather than mid-scan.
    public func warmUp() throws {
        _ = try loadImageModel()
        _ = try loadTextModel()
    }

    // MARK: - Image embedding

    public func embed(imageData: Data) async throws -> [Float] {
        guard let image = UIImage(data: imageData) else {
            throw EmbedderError.imageDecodeFailed
        }
        let pixels = try pixelBuffer(from: image)
        let model = try loadImageModel()

        let input = try MLDictionaryFeatureProvider(dictionary: ["pixel_values": pixels])
        let output = try await model.prediction(from: input)

        guard let value = output.featureValue(for: "image_embedding")?.multiArrayValue else {
            throw EmbedderError.unexpectedOutput("no image_embedding feature")
        }
        return try floats(from: value)
    }

    /// Embeds a search query.
    ///
    /// The caller tokenizes with `CLIPTokenizer`, which is in TokinoKit so its
    /// correctness is tested on Linux against open_clip's own output.
    public func embed(tokenIDs: [Int]) async throws -> [Float] {
        let model = try loadTextModel()

        let array = try MLMultiArray(
            shape: [1, NSNumber(value: descriptor.contextLength)],
            dataType: .int32
        )
        for index in 0..<descriptor.contextLength {
            array[[0, NSNumber(value: index)]] = NSNumber(
                value: Int32(index < tokenIDs.count ? tokenIDs[index] : 0)
            )
        }

        let input = try MLDictionaryFeatureProvider(dictionary: ["input_ids": array])
        let output = try await model.prediction(from: input)

        guard let value = output.featureValue(for: "text_embedding")?.multiArrayValue else {
            throw EmbedderError.unexpectedOutput("no text_embedding feature")
        }
        return try floats(from: value)
    }

    private func floats(from array: MLMultiArray) throws -> [Float] {
        guard array.count == descriptor.dimensions else {
            throw EmbedderError.unexpectedOutput(
                "expected \(descriptor.dimensions) values, got \(array.count)"
            )
        }
        // The model normalises its own output, so no normalisation here. Doing
        // it twice would be harmless but doing it in only one place keeps the
        // invariant findable.
        var result = [Float](repeating: 0, count: array.count)
        switch array.dataType {
        case .float32:
            let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
            result = Array(UnsafeBufferPointer(start: pointer, count: array.count))
        case .float16:
            // Core ML often hands back fp16 when the model was converted at
            // that precision. Widen rather than reinterpret.
            for index in 0..<array.count {
                result[index] = array[index].floatValue
            }
        case .double:
            let pointer = array.dataPointer.bindMemory(to: Double.self, capacity: array.count)
            for index in 0..<array.count { result[index] = Float(pointer[index]) }
        default:
            throw EmbedderError.unexpectedOutput("unsupported data type \(array.dataType)")
        }
        return result
    }

    // MARK: - Preprocessing

    /// Converts an image into the normalised CHW tensor the model expects.
    ///
    /// The model takes an already-normalised tensor rather than a Core ML image
    /// input, deliberately: the mean and standard deviation then live in
    /// `EmbeddingModelDescriptor` where they are visible and asserted by the
    /// parity test, instead of being buried in the model's preprocessing where
    /// a mismatch would be invisible.
    private func pixelBuffer(from image: UIImage) throws -> MLMultiArray {
        let size = descriptor.inputPixelSize
        guard let resized = image.resizedAndCropped(to: CGSize(width: size, height: size)),
              let cgImage = resized.cgImage
        else { throw EmbedderError.imageDecodeFailed }

        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: size * size * bytesPerPixel)

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &rgba,
                width: size,
                height: size,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { throw EmbedderError.imageDecodeFailed }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        )
        let pointer = array.dataPointer.bindMemory(to: Float.self, capacity: array.count)
        let mean = descriptor.pixelMean
        let standardDeviation = descriptor.pixelStandardDeviation
        let plane = size * size

        for y in 0..<size {
            for x in 0..<size {
                let source = (y * size + x) * bytesPerPixel
                let destination = y * size + x
                for channel in 0..<3 {
                    let raw = Float(rgba[source + channel]) / 255
                    pointer[channel * plane + destination] =
                        (raw - mean[channel]) / standardDeviation[channel]
                }
            }
        }
        return array
    }
}

extension UIImage {
    /// Scales to fill, then centre-crops — matching CLIP's own preprocessing,
    /// which resizes the short edge and takes a centre crop.
    ///
    /// Letterboxing instead would put grey bars in the frame and shift the
    /// embedding away from the training distribution.
    func resizedAndCropped(to target: CGSize) -> UIImage? {
        let scale = max(target.width / size.width, target.height / size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        let origin = CGPoint(
            x: (target.width - scaled.width) / 2,
            y: (target.height - scaled.height) / 2
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: origin, size: scaled))
        }
    }
}
