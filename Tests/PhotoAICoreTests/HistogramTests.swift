import CoreGraphics
import Testing
@testable import PhotoAICore

/// 检查器的直方图。
@Suite struct HistogramTests {
    /// 左半边纯色 `left`、右半边纯色 `right` 的图。
    func image(width: Int, height: Int, left: (CGFloat, CGFloat, CGFloat), right: (CGFloat, CGFloat, CGFloat)) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(srgbRed: left.0, green: left.1, blue: left.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: right.0, green: right.1, blue: right.2, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    @Test func countsChannelsAndLuminance() throws {
        let histogram = try #require(Histogram(image: image(width: 200, height: 100, left: (1, 0, 0), right: (0, 0, 0))))
        #expect(histogram.pixelCount == 20_000)
        #expect(histogram.red[255] == 10_000 && histogram.red[0] == 10_000)
        #expect(histogram.green[0] == 20_000 && histogram.blue[0] == 20_000)
        // 纯红的亮度约 0.2126 × 255 ≈ 54。
        #expect(histogram.luminance[54] == 10_000 && histogram.luminance[0] == 10_000)
        for channel in [histogram.red, histogram.green, histogram.blue, histogram.luminance] {
            #expect(channel.reduce(0, +) == 20_000)
        }
        // 纯红算高光溢出（一个通道到顶），纯黑算暗部死黑。
        #expect(histogram.highlightClipping == 0.5 && histogram.shadowClipping == 0.5)
    }

    @Test func midGrayHasNoClipping() throws {
        let histogram = try #require(Histogram(image: image(width: 64, height: 64, left: (0.5, 0.5, 0.5), right: (0.25, 0.25, 0.25))))
        #expect(histogram.highlightClipping == 0 && histogram.shadowClipping == 0)
        #expect(histogram.luminance.filter { $0 > 0 }.count == 2)
        #expect(histogram.luminance[255] == 0 && histogram.luminance[0] == 0)
    }

    @Test func largeImagesAreDownscaled() throws {
        let histogram = try #require(Histogram(image: image(width: 4000, height: 2000, left: (1, 1, 1), right: (0, 0, 0)), maximumEdge: 320))
        #expect(histogram.pixelCount == 320 * 160)
        #expect(abs(histogram.highlightClipping - 0.5) < 0.01)
    }
}
