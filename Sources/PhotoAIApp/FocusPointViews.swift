import AppKit
import PhotoAICore
import SwiftUI

// MARK: - 对焦框（迭代 B-10）

extension AppModel {
    /// 照片的对焦框，在后台查库，查过的记下（包括“没有”）。
    func loadFocusArea(of id: PhotoID) {
        guard focusAreas[id] == nil, focusLoading.insert(id).inserted, let reader else { return }
        Task.detached(priority: .userInitiated) { [weak self] in
            let area = (try? reader.focusArea(of: id)) ?? nil
            await MainActor.run { [weak self] in
                guard let self else { return }
                focusLoading.remove(id)
                if focusAreas.count > 500 { focusAreas.removeAll(keepingCapacity: true) }
                focusAreas[id] = .some(area)
            }
        }
    }

    func toggleFocusPoint() {
        guard viewMode != .grid else { return show("对焦框在单张和比较视图里显示") }
        showFocusPoint.toggle()
        show(showFocusPoint ? "显示对焦框（A 隐藏）" : "隐藏对焦框")
    }

    /// ⇧Z：以对焦框为中心放大到 100%，看焦点上清不清楚。
    func zoomToFocus() {
        guard viewMode == .single else {
            return show(viewMode == .compare ? "比较视图里各张的对焦点不同，在单张视图里用 ⇧Z" : "⇧Z 用于单张视图")
        }
        guard let id = focusedPhotoID else { return }
        guard case .some(let cached) = focusAreas[id] else {
            loadFocusArea(of: id)
            return show("正在读对焦位置，再按一次 ⇧Z")
        }
        guard let area = cached else { return show("这张照片没有对焦记录（目前认索尼；原片在线时读取）") }
        let center = CGPoint(x: area.centerX, y: area.centerY)
        if zoomed {
            zoomScale = 1
            zoomCenter = center
        } else {
            zoom(to: 1, at: center)
        }
    }

    /// 原片在线时在后台读还没读过的对焦框（只读文件头）。启动、扫描完、预览做完时各调一次。
    func startFocusReading() {
        // `PHOTOAI_FOCUS=off`：不读（测流畅度时排除第一次读卡的影响）。
        guard ProcessInfo.processInfo.environment["PHOTOAI_FOCUS"] != "off" else { return }
        guard focusTask == nil, let library, !onlineVolumes.isEmpty else { return }
        let mounts = onlineVolumes
        let started = Date()
        focusTask = Task.detached(priority: .utility) { [weak self] in
            let count = (try? FocusRunner(library: library).run(mountURLs: mounts, shouldStop: { Task.isCancelled })) ?? 0
            await MainActor.run { [weak self] in
                guard let self else { return }
                focusTask = nil
                if count > 0 {
                    Measurements.emit("对焦框：读了 \(count) 张，\(Measurements.milliseconds(since: started)) ms")
                    focusAreas = [:]
                    detailVersion &+= 1
                }
                if Set(onlineVolumes.keys) != Set(mounts.keys) { startFocusReading() }
            }
        }
    }
}

/// 照片上的对焦框：绿色细框，外面一圈深色描边，亮背景、暗背景都看得见。框太小时至少画 14 点。
struct FocusBoxShape: View {
    let area: FocusArea

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let width = max(area.width * size.width, 14), height = max(area.height * size.height, 14)
            let rect = CGRect(
                x: area.centerX * size.width - width / 2, y: area.centerY * size.height - height / 2, width: width, height: height
            )
            ZStack {
                Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 3.5)
                Rectangle().stroke(Color(red: 0.3, green: 1, blue: 0.4), lineWidth: 1.5)
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
        }
        .allowsHitTesting(false)
    }
}

/// 叠在照片上（单张、比较视图适合窗口时）：开着“显示对焦框”才查、才画。
struct FocusBoxOverlay: View {
    @Environment(AppModel.self) private var model
    let id: PhotoID

    var body: some View {
        if model.showFocusPoint {
            // 底下垫一层透明的：框还没查到时视图不能是空的，不然 task 不会跑。不接点击（单击照片要放大）。
            Color.clear
                .overlay {
                    if case .some(.some(let area)) = model.focusAreas[id] { FocusBoxShape(area: area) }
                }
                .allowsHitTesting(false)
                .task(id: id) { model.loadFocusArea(of: id) }
        }
    }
}

/// 检查器里的一行：显示对焦框的开关、放大到对焦点。用详情里一起读出来的框，翻页时不另外查库。
struct FocusPointRow: View {
    @Environment(AppModel.self) private var model
    let detail: PhotoDetail

    var body: some View {
        @Bindable var model = model
        HStack {
            Toggle("对焦框（A）", isOn: $model.showFocusPoint).toggleStyle(.checkbox)
            Spacer()
            if detail.focus != nil {
                Button("放大到对焦点（⇧Z）") {
                    let id = detail.summary.id
                    if model.viewMode != .single { model.openSingle(id) }
                    model.focusAreas[id] = .some(detail.focus)
                    model.zoomToFocus()
                }
                .buttonStyle(.link)
            } else {
                Text(detail.focusState == "none" ? "没有对焦记录" : "原片在线时读取").foregroundStyle(.secondary)
                    .help("目前认索尼相机（JPEG、ARW）；原片所在卷插着时在后台读，读过的卡拔掉也能显示")
            }
        }
        .font(.callout)
    }
}
