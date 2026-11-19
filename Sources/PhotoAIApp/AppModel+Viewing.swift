import AppKit
import Foundation
import PhotoAICore

/// 单张视图换上的原图：按屏幕尺寸解码的那一张，记下按多大解的，窗口变大了再解一次。
/// `nsImage` 只建一次：每次重画都新建的话，SwiftUI 当它是另一张图，打一次星就要重新上传一次大图。
struct SharpOriginal {
    let image: CGImage
    let nsImage: NSImage
    let maximumPixelSize: Int

    init(image: CGImage, maximumPixelSize: Int) {
        self.image = image
        nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        self.maximumPixelSize = maximumPixelSize
    }
}

// MARK: - 任意比例放大（计划 V-2）

extension AppModel {
    /// ⌘+ / ⌘− 的档位；“适合窗口”是最小的一档。捏合可以到 `maximumZoom`。
    static let zoomSteps: [CGFloat] = [0.5, 1, 2]
    static let maximumZoom: CGFloat = 4

    /// ⌘+：放大一档。适合窗口时从比适合窗口大的第一档开始。
    func zoomIn() {
        guard viewMode != .grid else { return show("放大用于单张和比较视图") }
        let current = zoomed ? zoomScale : fitScale
        guard let next = Self.zoomSteps.first(where: { $0 > current * 1.01 }) else { return }
        zoom(to: next)
    }

    /// ⌘−：缩小一档；下一档不比适合窗口大时回到适合窗口。
    func zoomOut() {
        guard zoomed else { return }
        if let next = Self.zoomSteps.last(where: { $0 < zoomScale * 0.99 }), next > fitScale * 1.01 {
            zoomScale = next
        } else {
            endZoom()
        }
    }

    /// 放大到 `scale`（1 = 100%）。还没放大时从 `center`（照片上 0–1 的位置）开始，并读原文件。
    func zoom(to scale: CGFloat, at center: CGPoint? = nil) {
        guard viewMode != .grid else { return }
        zoomScale = min(max(scale, 0.05), Self.maximumZoom)
        guard !zoomed else { return }
        zoomCenter = center ?? CGPoint(x: 0.5, y: 0.5)
        zoomed = true
        loadOriginalsForZoom()
    }

    /// 捏合时比例变了（比较视图各格共用）。
    func setZoomScale(_ scale: CGFloat) {
        if abs(scale - zoomScale) > 0.001 { zoomScale = scale }
    }

    /// 角上显示的比例。
    var zoomPercent: String { "\(Int((zoomScale * 100).rounded()))%" }
}

// MARK: - 单张视图换原图（计划 V-3）

extension AppModel {
    /// 在一张照片上停 0.3 秒后由单张视图调用：原片所在卷在线就按屏幕尺寸读原图换掉 1600 预览，再读后一张、前一张。
    /// 卷离线、文件读不到都安静地留在预览。这里**不**把位置改为历史：发现缺失的时机仍只有重扫、导出 / 100% 放大、清卡（设计稿 §4.1）。
    func loadSharpOriginals(around id: PhotoID, maximumPixelSize: Int) {
        // 屏幕上用不到比 1600 预览大多少的图（小窗口、非 Retina）就不读。
        guard maximumPixelSize > PreviewSize.preview.rawValue * 11 / 10, let reader else { return }
        let ids = sharpNeighborhood(of: id)
        sharpOriginals = sharpOriginals.filter { ids.contains($0.key) && $0.value.maximumPixelSize * 10 >= maximumPixelSize * 9 }
        let wanted = ids.filter { sharpOriginals[$0] == nil }
        guard !wanted.isEmpty else { return }
        sharpTask?.cancel()
        let finder = makeFinder()
        let started = Date()
        sharpTask = Task.detached(priority: .utility) { [weak self] in
            for target in wanted {
                guard !Task.isCancelled else { return }
                let sources = (try? reader.presentSources(of: [target]))?[target] ?? []
                let online = sources.filter { finder.mounts[$0.volumeID] != nil }
                guard !online.isEmpty, let found = finder.lookupForViewing(online).found,
                      let image = OriginalDecoder.decode(found.url, maximumPixelSize: maximumPixelSize),
                      max(image.width, image.height) > PreviewSize.preview.rawValue else { continue }
                await MainActor.run { [weak self] in
                    guard let self, !Task.isCancelled, let focus = focusedPhotoID, sharpNeighborhood(of: focus).contains(target) else { return }
                    sharpOriginals[target] = SharpOriginal(image: image, maximumPixelSize: maximumPixelSize)
                    if target == id {
                        Measurements.record("V-3 换原图 \(found.source.fileName) \(image.width)×\(image.height)", since: started, count: 1)
                    }
                }
            }
        }
    }

    /// 焦点、后一张、前一张。
    func sharpNeighborhood(of id: PhotoID) -> [PhotoID] {
        guard let index = resultIndex[id] else { return [id] }
        return [0, 1, -1].compactMap { resultIDs.indices.contains(index + $0) ? resultIDs[index + $0] : nil }
    }

    func dropSharpOriginals() {
        sharpTask?.cancel()
        sharpTask = nil
        sharpOriginals = [:]
    }
}
