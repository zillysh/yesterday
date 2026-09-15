import Accelerate
import CoreImage
import CoreML
import Foundation
import UIKit

/// MobileCLIP-S0 image + text encoders in one embedding space.
actor PhotoEmbedder {
    static let shared = PhotoEmbedder()

    private let targetSize = CGSize(width: 256, height: 256)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var imageModel: MLModel?
    private var textModel: MLModel?
    private var tokenizer: CLIPTokenizer?
    private var loadFailed = false
    private(set) var dimension: Int = 512

    var isReady: Bool { imageModel != nil && textModel != nil && tokenizer?.isReady == true }

    func prepare() async {
        guard imageModel == nil, textModel == nil, !loadFailed else { return }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuAndNeuralEngine

            guard let imageURL = Self.modelURL(named: "mobileclip_s0_image"),
                  let textURL = Self.modelURL(named: "mobileclip_s0_text")
            else {
                loadFailed = true
                return
            }

            async let imageCompiled = Self.compileIfNeeded(imageURL)
            async let textCompiled = Self.compileIfNeeded(textURL)
            let (imgURL, txtURL) = try await (imageCompiled, textCompiled)

            imageModel = try MLModel(contentsOf: imgURL, configuration: config)
            textModel = try MLModel(contentsOf: txtURL, configuration: config)
            tokenizer = CLIPTokenizer()
            if tokenizer?.isReady != true {
                loadFailed = true
                imageModel = nil
                textModel = nil
            }
        } catch {
            loadFailed = true
            imageModel = nil
            textModel = nil
        }
    }

    func embedText(_ text: String) async -> [Float]? {
        await prepare()
        guard let textModel, let tokenizer, tokenizer.isReady else { return nil }
        let ids = tokenizer.encodeFull(text: text)
        do {
            let input = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (i, id) in ids.enumerated() {
                input[i] = NSNumber(value: id)
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "text": MLFeatureValue(multiArray: input)
            ])
            let out = try await textModel.prediction(from: provider)
            guard let arr = out.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
            let vector = Self.floats(from: arr)
            dimension = vector.count
            return Self.l2Normalize(vector)
        } catch {
            return nil
        }
    }

    func embedImage(_ image: UIImage) async -> [Float]? {
        await prepare()
        guard let imageModel, let buffer = pixelBuffer(from: image) else { return nil }
        do {
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "image": MLFeatureValue(pixelBuffer: buffer)
            ])
            let out = try await imageModel.prediction(from: provider)
            guard let arr = out.featureValue(for: "final_emb_1")?.multiArrayValue else { return nil }
            let vector = Self.floats(from: arr)
            dimension = vector.count
            return Self.l2Normalize(vector)
        } catch {
            return nil
        }
    }

    private static func modelURL(named name: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: "mlpackage", subdirectory: "Models") {
            return url
        }
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") { return url }
        if let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc", subdirectory: "Models") {
            return url
        }
        return nil
    }

    private static func compileIfNeeded(_ url: URL) async throws -> URL {
        if url.pathExtension == "mlmodelc" { return url }
        let compiled = try await MLModel.compileModel(at: url)
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MobileCLIP", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mlmodelc")
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: compiled, to: dest)
        return dest
    }

    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard var ci = CIImage(image: image) ?? image.cgImage.map(CIImage.init(cgImage:)) else {
            return nil
        }
        ci = cropToSquare(ci)
        ci = resize(ci, to: targetSize)

        let width = Int(targetSize.width)
        let height = Int(targetSize.height)
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attrs as CFDictionary,
            &buffer
        )
        guard let buffer else { return nil }
        ciContext.render(ci, to: buffer)
        return buffer
    }

    private func cropToSquare(_ image: CIImage) -> CIImage {
        let size = min(image.extent.width, image.extent.height)
        let x = (image.extent.width - size) / 2
        let y = (image.extent.height - size) / 2
        let rect = CGRect(x: x, y: y, width: size, height: size)
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -x, y: -y))
    }

    private func resize(_ image: CIImage, to size: CGSize) -> CIImage {
        let sx = size.width / image.extent.width
        let sy = size.height / image.extent.height
        return image.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
    }

    static func floats(from array: MLMultiArray) -> [Float] {
        let count = array.count
        var out = [Float](repeating: 0, count: count)
        if array.dataType == .float32 {
            array.withUnsafeBufferPointer(ofType: Float.self) { ptr in
                for i in 0..<count { out[i] = ptr[i] }
            }
        } else {
            for i in 0..<count { out[i] = array[i].floatValue }
        }
        return out
    }

    static func l2Normalize(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        vDSP_svesq(v, 1, &sum, vDSP_Length(v.count))
        let norm = sqrt(sum)
        guard norm > 1e-8 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var divisor = norm
        vDSP_vsdiv(v, 1, &divisor, &out, 1, vDSP_Length(v.count))
        return out
    }
}
