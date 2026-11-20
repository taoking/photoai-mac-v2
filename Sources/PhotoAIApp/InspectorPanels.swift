import AppKit
import ImageIO
import PhotoAICore
import SwiftUI

// MARK: - 直方图

extension AppModel {
    /// 照片的直方图：按 480 缩略图在后台算，记下最近的几百张。缩略图还没生成就没有。
    func loadHistogram(of id: PhotoID) async -> Histogram? {
        if let cached = histograms[id] { return cached }
        guard let store = previewStore else { return nil }
        let url = store.url(for: id, size: .thumb)
        let histogram = await Task.detached(priority: .utility) { () -> Histogram? in
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 320
            ] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return Histogram(image: image)
        }.value
        if let histogram {
            if histograms.count >= 300 { histograms.removeAll(keepingCapacity: true) }
            histograms[id] = histogram
        }
        return histogram
    }
}

/// 检查器顶上的直方图：红绿蓝叠在一起，白色是亮度；高光溢出、暗部死黑超过 0.5% 时在下面提示。
/// 在一张照片上停 0.12 秒才算，快速翻页时不算中间的，不和打星、翻页抢时间。
struct HistogramPanel: View {
    @Environment(AppModel.self) private var model
    let photoID: PhotoID
    @State private var loaded: (id: PhotoID, histogram: Histogram?)?

    var body: some View {
        let histogram = loaded?.id == photoID ? loaded?.histogram : nil
        VStack(alignment: .leading, spacing: 4) {
            HistogramShape(histogram: histogram)
                .frame(height: 76)
                .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if loaded?.id == photoID, histogram == nil {
                        Text("缩略图还没生成").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .help("按缩略图算：RAW 用的是相机内嵌的 JPEG，和相机屏幕上的直方图一样")
            if let histogram, histogram.highlightClipping >= 0.005 || histogram.shadowClipping >= 0.005 {
                HStack(spacing: 10) {
                    if histogram.shadowClipping >= 0.005 {
                        Label("暗部死黑 \(Self.percent(histogram.shadowClipping))", systemImage: "arrowtriangle.left.fill")
                            .foregroundStyle(.blue)
                    }
                    Spacer(minLength: 0)
                    if histogram.highlightClipping >= 0.005 {
                        Label("高光溢出 \(Self.percent(histogram.highlightClipping))", systemImage: "arrowtriangle.right.fill")
                            .foregroundStyle(.red)
                    }
                }
                .labelStyle(.titleAndIcon)
                .font(.caption2)
            }
        }
        .task(id: photoID) {
            if model.histograms[photoID] == nil {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
            }
            let histogram = await model.loadHistogram(of: photoID)
            guard !Task.isCancelled else { return }
            loaded = (photoID, histogram)
        }
    }

    static func percent(_ value: Double) -> String {
        value < 0.1 ? String(format: "%.1f%%", value * 100) : "\(Int((value * 100).rounded()))%"
    }
}

/// 画直方图：每个通道按最高的一格归一，开平方让暗淡的部分也看得出来；两端那一格常常特别高，不参与归一。
private struct HistogramShape: View {
    let histogram: Histogram?

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            func path(_ bins: [UInt32]) -> Path {
                let peak = max(1, bins[1..<255].max() ?? 1)
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for (index, count) in bins.enumerated() {
                    let height = min(1, (Double(count) / Double(peak)).squareRoot()) * (size.height - 4)
                    path.addLine(to: CGPoint(x: Double(index) / 255 * size.width, y: size.height - height))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                return path
            }
            context.blendMode = .plusLighter
            context.fill(path(histogram.red), with: .color(Color(red: 0.9, green: 0.2, blue: 0.2).opacity(0.75)))
            context.fill(path(histogram.green), with: .color(Color(red: 0.2, green: 0.8, blue: 0.3).opacity(0.75)))
            context.fill(path(histogram.blue), with: .color(Color(red: 0.25, green: 0.4, blue: 1).opacity(0.75)))
            context.blendMode = .normal
            context.stroke(path(histogram.luminance), with: .color(.white.opacity(0.85)), lineWidth: 1)
        }
        .padding(.horizontal, 2)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// 直方图下面一行拍摄参数：焦距、光圈、快门、ISO，等宽数字，和相机屏幕上的顺序一样。
struct ExposureStrip: View {
    let detail: PhotoDetail

    var body: some View {
        let items = ExposureText.parts(detail)
        if !items.isEmpty {
            HStack {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    if index > 0 { Spacer(minLength: 4) }
                    Text(item)
                }
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 导航器

/// 单张视图放大时：整张照片的小图，框出现在看的地方；在小图上点或拖，画面跟过去。
struct NavigatorPanel: View {
    @Environment(AppModel.self) private var model
    let photoID: PhotoID

    var body: some View {
        let image = model.previews.cached(photoID) ?? model.thumbnails.cached(photoID)
        let photo = model.photo(photoID)
        let aspect: CGFloat = if let width = photo?.width, let height = photo?.height, width > 0, height > 0 {
            CGFloat(width) / CGFloat(height)
        } else if let image, image.size.height > 0 {
            image.size.width / image.size.height
        } else {
            1.5
        }
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { proxy in
                let size = proxy.size
                let viewport = model.zoomViewport
                let center = Self.reachable(model.zoomCenter, viewport: viewport)
                ZStack(alignment: .topLeading) {
                    if let image {
                        Image(nsImage: image).resizable().interpolation(.medium)
                    } else {
                        Color.secondary.opacity(0.2)
                    }
                    // 框外压暗，框里是正在看的部分。
                    let frame = CGRect(
                        x: (center.x - viewport.width / 2) * size.width, y: (center.y - viewport.height / 2) * size.height,
                        width: viewport.width * size.width, height: viewport.height * size.height
                    )
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: size))
                        path.addRect(frame)
                    }
                    .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                    Rectangle()
                        .stroke(Color.white, lineWidth: 1.5)
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    let point = CGPoint(x: value.location.x / max(size.width, 1), y: value.location.y / max(size.height, 1))
                    model.setZoomCenter(Self.reachable(point, viewport: viewport))
                })
            }
            .aspectRatio(aspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            Text("导航器 · \(model.zoomPercent)").font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 框不出照片：中心离边至少半个可视区域。
    static func reachable(_ point: CGPoint, viewport: CGSize) -> CGPoint {
        func clamp(_ value: CGFloat, _ visible: CGFloat) -> CGFloat {
            let half = min(visible, 1) / 2
            return half >= 0.5 ? 0.5 : min(max(value, half), 1 - half)
        }
        return CGPoint(x: clamp(point.x, viewport.width), y: clamp(point.y, viewport.height))
    }
}
