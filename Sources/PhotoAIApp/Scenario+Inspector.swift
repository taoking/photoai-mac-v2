import AppKit
import PhotoAICore

/// `PHOTOAI_SCENARIO=inspector`：检查器的直方图和导航器（阶段版本 0.6）。准备工作见 `Scripts/inspector-test.sh`。
///
/// - 直方图：单张视图停在一张照片上算出来，四个通道各数满全部像素；快速翻页时不算中间的照片；
/// - 导航器：只在单张视图放大时出现；框的大小和放大的视图里看得见的部分一致，换比例跟着变；
///   在导航器上点（和拖动走同一个方法），放大的画面跟过去，框不出照片；回到适合窗口后导航器收起。
/// 不需要卡插着（卷离线时放大的是预览）。只对库的副本用。
extension ScenarioRunner {
    func buildInspector() {
        var first: PhotoID = 0
        var computedBefore = 0

        func viewport() -> CGSize? {
            guard let view = zoomViews().first, let canvas = view.documentView, canvas.frame.width > 0 else { return nil }
            let bounds = view.contentView.bounds
            return CGSize(width: min(bounds.width / canvas.frame.width, 1), height: min(bounds.height / canvas.frame.height, 1))
        }

        wait("照片读好", timeout: 30) { [self] in model.photoCount > 0 }
        step("单张视图打开第一张有缩略图的照片") { [self] in
            model.selection = .all
            model.sort = .captureDateDescending
            model.showInspector = true
        }
        step("打开") { [self] in
            first = model.resultIDs.first { model.photo($0)?.thumbState == .ready } ?? 0
            check(first != 0, "找到有缩略图的照片")
            model.openSingle(first)
        }
        wait("直方图算好", timeout: 5) { [self] in model.histograms[first] != nil }
        step("直方图") { [self] in
            guard let histogram = model.histograms[first] else { return check(false, "直方图算出来") }
            let sums = [histogram.red, histogram.green, histogram.blue, histogram.luminance].map { $0.reduce(0) { $0 + Int($1) } }
            check(histogram.pixelCount > 10_000 && sums.allSatisfy { $0 == histogram.pixelCount },
                  "四个通道各数满 \(histogram.pixelCount) 个像素（按缩略图，长边 320）")
            check(!model.zoomed, "没放大时导航器不出现（只有直方图）")
            snapshot("inspector-histogram")
        }
        step("快速翻页 20 张（每张 40 ms）") { [self] in
            computedBefore = model.histograms.count
            for index in 0..<20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(40 * index)) {
                    MainActor.assumeIsolated { self.model.move(1) }
                }
            }
        }
        asyncStep("等翻完再停 0.6 秒") { done in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated { done() } }
        }
        step("翻页途中不算") { [self] in
            let added = model.histograms.count - computedBefore
            check(added <= 2, "翻过 20 张只多算了 \(added) 张（停下的那张，中间的不算）")
            check(model.focusedPhotoID.flatMap { model.histograms[$0] } != nil, "停下的那张算好了")
            model.openSingle(first)
        }

        // MARK: 导航器

        step("放大到 100%") { [self] in model.zoom(to: 1, at: CGPoint(x: 0.5, y: 0.5)) }
        step("导航器的框") { [self] in
            guard let shown = viewport() else { return check(false, "找到放大的视图") }
            let reported = model.zoomViewport
            check(model.zoomed && model.viewMode == .single, "单张视图放大中，导航器出现")
            check(reported.width < 1 && reported.height < 1, String(format: "100%% 时只看得见一部分：%.3f × %.3f", reported.width, reported.height))
            check(abs(reported.width - shown.width) < 0.01 && abs(reported.height - shown.height) < 0.01,
                  String(format: "框的大小和画面一致（画面 %.3f × %.3f）", shown.width, shown.height))
            snapshot("inspector-navigator-100")
        }
        step("放大到 200%") { [self] in model.zoomIn() }
        step("换比例框跟着变") { [self] in
            let reported = model.zoomViewport
            guard let shown = viewport() else { return check(false, "找到放大的视图") }
            check(abs(model.zoomScale - 2) < 0.01, "比例 200%")
            check(abs(reported.width - shown.width) < 0.01 && abs(reported.height - shown.height) < 0.01,
                  String(format: "200%% 时框 %.3f × %.3f，和画面一致", reported.width, reported.height))
        }
        step("在导航器左上角点一下") { [self] in
            model.setZoomCenter(NavigatorPanel.reachable(CGPoint(x: 0.02, y: 0.03), viewport: model.zoomViewport))
        }
        step("画面跟到左上角") { [self] in
            let wanted = NavigatorPanel.reachable(CGPoint(x: 0.02, y: 0.03), viewport: model.zoomViewport)
            let center = zoomViews().first?.visibleCenter ?? .zero
            check(near(center, wanted), String(format: "画面中心 (%.3f, %.3f)，导航器给的 (%.3f, %.3f)", center.x, center.y, wanted.x, wanted.y))
            check(abs(wanted.x - model.zoomViewport.width / 2) < 0.001 && abs(wanted.y - model.zoomViewport.height / 2) < 0.001,
                  "点到角上时框贴着照片的边，不出照片")
            snapshot("inspector-navigator-corner")
        }
        step("在导航器中间偏右下点一下") { [self] in model.setZoomCenter(CGPoint(x: 0.7, y: 0.6)) }
        step("画面跟过去") { [self] in
            let center = zoomViews().first?.visibleCenter ?? .zero
            check(near(center, CGPoint(x: 0.7, y: 0.6)), String(format: "画面中心 (%.3f, %.3f)", center.x, center.y))
        }
        step("⌘0 回到适合窗口") { [self] in model.endZoom() }
        step("导航器收起") { [self] in
            check(!model.zoomed, "回到适合窗口，导航器收起，只剩直方图")
            model.selectedPhotoIDs = Set(model.resultIDs.prefix(3))
            model.setView(.compare)
        }
        step("比较视图") { [self] in
            check(model.viewMode == .compare, "比较视图里检查器显示焦点格的直方图，不显示导航器（导航器只在单张视图）")
            snapshot("inspector-compare")
            model.setView(.grid)
        }
    }
}
