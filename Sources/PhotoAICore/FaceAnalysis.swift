import CoreGraphics
import CoreML
import Foundation
import Vision

/// 照片里找到的一张脸。
public struct DetectedFace: Sendable, Equatable {
    /// 在照片里的位置，0–1，左上为原点。
    public var box: CGRect
    /// L2 归一化的 512 维特征；脸太小、太糊时为空（只记位置，不参与认人）。
    public var feature: [Float]
    /// Vision 的拍摄质量（0–1，越大越清楚、越正），挑人物封面用。
    public var quality: Float
}

/// 人脸识别模型（ArcFace R50，`Scripts/install-face-model.sh` 装）。没装时人物识别不跑。
public final class FaceEmbedder: @unchecked Sendable {
    public static let featureLength = 512
    private let model: MLModel
    private let lock = NSLock()

    /// 默认位置：真实库所在的 `PhotoAI-Mac-v2/Models`，不跟着 `PHOTOAI_LIBRARY_DIR` 换（测试用的库副本也用同一个模型）。
    public static var defaultModelURL: URL {
        if let override = ProcessInfo.processInfo.environment["PHOTOAI_FACE_MODEL"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("PhotoAI-Mac-v2/Models/ArcFace-R50.mlmodelc", isDirectory: true)
    }

    public init(modelURL: URL = FaceEmbedder.defaultModelURL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    /// 对齐好的 112×112 人脸 → 归一化的特征。
    public func feature(of alignedFace: CGImage) throws -> [Float] {
        guard let constraint = model.modelDescription.inputDescriptionsByName["face"]?.imageConstraint else {
            throw FaceModelError.unexpectedModel
        }
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "face": try MLFeatureValue(cgImage: alignedFace, constraint: constraint)
        ])
        let output = try lock.withLock { try model.prediction(from: input) }
        guard let array = output.featureValue(for: "feature")?.multiArrayValue,
              array.count == Self.featureLength else { throw FaceModelError.unexpectedModel }
        var values = [Float](repeating: 0, count: array.count)
        for index in 0..<array.count { values[index] = array[index].floatValue }
        return FaceMath.normalized(values)
    }
}

public enum FaceModelError: Error, CustomStringConvertible {
    case unexpectedModel
    public var description: String { "人脸识别模型的输入输出和预期不一样，重新运行 Scripts/install-face-model.sh" }
}

/// 找脸、对齐、算特征。照片用本机的 1600 预览，卷离线也能做。
public struct FaceAnalyzer: Sendable {
    /// 脸的宽度不到这么多像素（在 1600 预览上）就只记位置：太小认不准，多是背景里的路人。
    public var minimumFeatureWidth: CGFloat = 48
    /// 拍摄质量低于这个值（糊、背光、侧过去）也只记位置。
    public var minimumQuality: Float = 0
    public var embedder: FaceEmbedder

    public init(embedder: FaceEmbedder) {
        self.embedder = embedder
    }

    public func faces(in image: CGImage) throws -> [DetectedFace] {
        // 用旧的 VNDetectFaceLandmarksRequest：macOS 27 上新的 DetectFaceLandmarksRequest 对多数脸给出
        // 框外的特征点（真实库 77 张脸里 69 张），旧接口只有 2 张。
        let handler = VNImageRequestHandler(cgImage: image)
        let landmarks = VNDetectFaceLandmarksRequest()
        try handler.perform([landmarks])
        let found = landmarks.results ?? []
        guard !found.isEmpty else { return [] }
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        qualityRequest.inputFaceObservations = found
        try handler.perform([qualityRequest])
        let qualities = (qualityRequest.results ?? []).map { $0.faceCaptureQuality ?? 0 }
        let size = CGSize(width: image.width, height: image.height)
        var faces: [DetectedFace] = []
        for (index, observation) in found.enumerated() {
            let quality = index < qualities.count ? qualities[index] : 0
            // Vision 的框以左下为原点。
            let box = observation.boundingBox
            let topLeftBox = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
            var feature: [Float] = []
            if box.width * size.width >= minimumFeatureWidth, quality >= minimumQuality, let landmarks = observation.landmarks,
               let points = FaceAlignment.fivePoints(landmarks, imageSize: size),
               let aligned = FaceAlignment.align(image, points: points) {
                feature = try embedder.feature(of: aligned)
            }
            faces.append(DetectedFace(box: topLeftBox, feature: feature, quality: quality))
        }
        return faces
    }
}

/// 按 ArcFace 的标准五点（两眼、鼻尖、两嘴角）把脸摆正成 112×112。
public enum FaceAlignment {
    /// ArcFace 训练时用的五点位置（112×112，左上为原点）。
    static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041)
    ]

    /// Vision 的特征点 → 五点（像素，左上为原点），顺序同 `template`：画面左边的眼睛在前。
    /// 特征点落在框外时（偶尔会有）返回 nil，这张脸只记位置。
    static func fivePoints(_ landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region, region.normalizedPoints.allSatisfy({ (0...1).contains($0.x) && (0...1).contains($0.y) })
            else { return [] }
            return region.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
        }
        guard let pupilA = points(landmarks.leftPupil).first, let pupilB = points(landmarks.rightPupil).first,
              let noseTip = points(landmarks.noseCrest).max(by: { $0.y < $1.y }) else { return nil }
        let lips = points(landmarks.outerLips)
        guard let mouthLeft = lips.min(by: { $0.x < $1.x }), let mouthRight = lips.max(by: { $0.x < $1.x }) else {
            return nil
        }
        let eyes = pupilA.x < pupilB.x ? [pupilA, pupilB] : [pupilB, pupilA]
        return eyes + [noseTip, mouthLeft, mouthRight]
    }

    /// 相似变换（缩放 + 旋转 + 平移）把五点对到模板上，最小二乘。
    static func similarity(from source: [CGPoint], to target: [CGPoint]) -> CGAffineTransform {
        let count = CGFloat(source.count)
        let sourceMean = source.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / count, y: $0.y + $1.y / count) }
        let targetMean = target.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / count, y: $0.y + $1.y / count) }
        var dot: CGFloat = 0, cross: CGFloat = 0, norm: CGFloat = 0
        for (s, t) in zip(source, target) {
            let sx = s.x - sourceMean.x, sy = s.y - sourceMean.y
            let tx = t.x - targetMean.x, ty = t.y - targetMean.y
            dot += sx * tx + sy * ty
            cross += sx * ty - sy * tx
            norm += sx * sx + sy * sy
        }
        let a = dot / max(norm, 1e-9), b = cross / max(norm, 1e-9)
        // x' = a·x − b·y + tx，y' = b·x + a·y + ty
        return CGAffineTransform(
            a: a, b: b, c: -b, d: a,
            tx: targetMean.x - (a * sourceMean.x - b * sourceMean.y),
            ty: targetMean.y - (b * sourceMean.x + a * sourceMean.y)
        )
    }

    static func align(_ image: CGImage, points: [CGPoint], side: Int = 112) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let height = CGFloat(image.height)
        // CGContext 以左下为原点：先把画布坐标翻成左上原点，套变换，再翻回去。
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(side))
        context.interpolationQuality = .high
        context.concatenate(flipIn.concatenating(similarity(from: points, to: template)).concatenating(flipOut))
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: height))
        return context.makeImage()
    }
}

public enum FaceMath {
    public static func normalized(_ vector: [Float]) -> [Float] {
        let length = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return length > 0 ? vector.map { $0 / length } : vector
    }

    /// 两个归一化向量的余弦相似度。
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        var sum: Float = 0
        for index in 0..<min(a.count, b.count) { sum += a[index] * b[index] }
        return sum
    }

    public static func data(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    public static func vector(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
