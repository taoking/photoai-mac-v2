import CoreGraphics
import Foundation

/// 照片的直方图：红、绿、蓝和亮度各 256 格。按缩略图算（480 预览），选片看曝光够用，几毫秒算完。
/// RAW 的缩略图来自相机内嵌的 JPEG，和相机屏幕上的直方图是同一种（不是 RAW 数据本身）。
public struct Histogram: Equatable, Sendable {
    public var red: [UInt32]
    public var green: [UInt32]
    public var blue: [UInt32]
    public var luminance: [UInt32]
    public var pixelCount: Int

    /// 最亮一格（255）和最暗一格（0）的像素占比：任一通道到顶 / 到底就算。用来提示高光溢出、暗部死黑。
    public var highlightClipping: Double
    public var shadowClipping: Double

    /// 长边缩到 `maximumEdge` 再数，大图也只数几万个像素。
    public init?(image: CGImage, maximumEdge: Int = 320) {
        let scale = min(1, Double(maximumEdge) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var red = [UInt32](repeating: 0, count: 256)
        var green = red, blue = red, luminance = red
        var highs = 0, lows = 0
        for index in 0..<(width * height) {
            let r = Int(pixels[index * 4]), g = Int(pixels[index * 4 + 1]), b = Int(pixels[index * 4 + 2])
            red[r] += 1
            green[g] += 1
            blue[b] += 1
            // Rec. 709 的亮度权重，整数算：(0.2126, 0.7152, 0.0722) × 1024。
            luminance[(218 * r + 732 * g + 74 * b) >> 10] += 1
            if r == 255 || g == 255 || b == 255 { highs += 1 }
            if r == 0 && g == 0 && b == 0 { lows += 1 }
        }
        self.red = red
        self.green = green
        self.blue = blue
        self.luminance = luminance
        pixelCount = width * height
        highlightClipping = Double(highs) / Double(pixelCount)
        shadowClipping = Double(lows) / Double(pixelCount)
    }
}
